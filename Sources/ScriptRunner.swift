import Foundation
import AppKit
import Darwin

/// Music sometimes never answers an Apple Event, even beyond AppleScript's
/// own timeout. Run each script in a child that we can stop and reap instead
/// of leaving an in-process NSAppleScript and its queue blocked forever.
final class ScriptRunner {
    // Reading a large playlist must not hold up polling or a playback command.
    static let shared = ScriptRunner(label: "library", deadline: 20)
    static let state = ScriptRunner(label: "state", deadline: 5)
    static let transport = ScriptRunner(label: "transport", deadline: 5)

    private let queue: DispatchQueue
    private let deadline: TimeInterval
    private let makeProcess: () -> Process
    private let inFlightLock = NSLock()
    private var inFlightSince: Date?

    struct ScriptError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(label: String = "library", deadline: TimeInterval = 20,
         makeProcess: @escaping () -> Process = { Process() }) {
        precondition(deadline.isFinite && deadline > 0)
        self.queue = DispatchQueue(label: "jp.menuqueue.applescript.\(label)")
        self.deadline = deadline
        self.makeProcess = makeProcess
    }

    var stalledSeconds: TimeInterval {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlightSince.map { Date().timeIntervalSince($0) } ?? 0
    }

    @discardableResult
    func run(_ source: String) throws -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(string: try string(source))
    }

    func string(_ source: String) throws -> String {
        try queue.sync {
            inFlightLock.lock(); inFlightSince = Date(); inFlightLock.unlock()
            defer { inFlightLock.lock(); inFlightSince = nil; inFlightLock.unlock() }
            return try execute(source)
        }
    }

    private func execute(_ source: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("menuqueue-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ScriptError(message: "AppleScriptの出力ファイルを作成できませんでした")
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }

        let finished = DispatchSemaphore(value: 0)
        let process = makeProcess()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Human-readable output preserves strings, their metadata newlines,
        // and the record separators used by the Music bridge.
        process.arguments = ["-s", "h", "-e", source]
        // A playlist can exceed a pipe's capacity. File-backed output lets
        // the child finish regardless of when this thread reads the result.
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + deadline) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ScriptError(message: "ミュージックからの応答が\(Int(deadline))秒以内に届きませんでした。もう一度操作してください")
        }
        guard process.terminationStatus == 0 else {
            let data = try Data(contentsOf: errorURL)
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScriptError(message: message.isEmpty ? "AppleScriptの実行に失敗しました" : message)
        }
        let data = try Data(contentsOf: outputURL)
        guard var result = String(data: data, encoding: .utf8) else {
            throw ScriptError(message: "AppleScriptの出力を読み取れませんでした")
        }
        // osascript appends exactly one line feed. Removing all whitespace
        // would change a track name or the final metadata field.
        if result.hasSuffix("\n") { result.removeLast() }
        return result
    }
}
