import Foundation

/// A small, append-only record of what the queue decided and why.
///
/// Playback problems — a song skipped, playback stopping, a stall — happen
/// while nobody is watching and leave nothing behind. With this, the next
/// report can be answered from what actually happened instead of guesses.
///
/// Written only by the installed app (its bundle identifier), so test runs and
/// command-line harnesses never mix their events into the real log. Kept
/// small: once it passes 256 KB the older half is dropped.
final class EventLog {
    static let shared = EventLog()

    private let lock = NSLock()
    private let url: URL?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        // Diagnostic harnesses can point the log somewhere of their own.
        if let path = ProcessInfo.processInfo.environment["MENUQUEUE_EVENTLOG"] {
            url = URL(fileURLWithPath: path)
            return
        }
        guard Bundle.main.bundleIdentifier == "jp.local.menuqueue" else { url = nil; return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("events.log")
    }

    static var path: String? { shared.url?.path }

    func note(_ message: String) {
        guard let url else { return }
        lock.lock(); defer { lock.unlock() }
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            let size = handle.offsetInFile
            try? handle.close()
            if size > 256 * 1024 { trim(url) }
        } else {
            try? data.write(to: url)
        }
    }

    private func trim(_ url: URL) {
        guard let all = try? Data(contentsOf: url) else { return }
        var tail = all.suffix(from: all.count / 2)
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: newline + 1) }
        try? Data(tail).write(to: url, options: .atomic)
    }
}
