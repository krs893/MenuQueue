import Foundation
import AppKit
import ApplicationServices

struct UpNextRow: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var subtitle: String
}

/// Reads Music.app's own "次に再生 / Up Next" list through the accessibility
/// tree. This is unavoidably best-effort: the list only exists while its
/// popover is open, and Apple can rename or restructure it in any update.
/// Everything here degrades to a readable error instead of crashing.
enum UpNextReader {

    enum ReadError: LocalizedError {
        case notTrusted
        case notRunning
        case buttonNotFound
        case listNotFound

        var errorDescription: String? {
            switch self {
            case .notTrusted:     return "アクセシビリティの許可が必要です（システム設定 › プライバシーとセキュリティ › アクセシビリティ）"
            case .notRunning:     return "Music.app が起動していません"
            case .buttonNotFound: return "Music.app の「次に再生」ボタンが見つかりませんでした"
            case .listNotFound:   return "「次に再生」リストを読み取れませんでした（ウインドウが最小化されている可能性があります）"
            }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: AX helpers

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func str(_ el: AXUIElement, _ name: String) -> String {
        (attr(el, name) as? String) ?? ""
    }

    private static func role(_ el: AXUIElement) -> String { str(el, kAXRoleAttribute) }

    private static func labelBlob(_ el: AXUIElement) -> String {
        [str(el, kAXTitleAttribute),
         str(el, kAXDescriptionAttribute),
         str(el, kAXHelpAttribute),
         str(el, kAXIdentifierAttribute)]
            .joined(separator: " ")
            .lowercased()
    }

    private static let upNextKeywords = [
        "up next", "playing next", "次に再生", "再生待ち", "queue", "キュー", "upnext"
    ]

    private static func matchesUpNext(_ blob: String) -> Bool {
        upNextKeywords.contains { blob.contains($0) }
    }

    private static func find(in el: AXUIElement, depth: Int = 0, limit: Int = 22,
                             _ test: (AXUIElement) -> Bool) -> AXUIElement? {
        if depth > limit { return nil }
        if test(el) { return el }
        for child in children(el) {
            if let hit = find(in: child, depth: depth + 1, limit: limit, test) { return hit }
        }
        return nil
    }

    private static func collect(in el: AXUIElement, depth: Int = 0, limit: Int = 22,
                                into out: inout [AXUIElement], _ test: (AXUIElement) -> Bool) {
        if depth > limit { return }
        if test(el) { out.append(el) }
        for child in children(el) {
            collect(in: child, depth: depth + 1, limit: limit, into: &out, test)
        }
    }

    private static func texts(of el: AXUIElement) -> [String] {
        var found: [AXUIElement] = []
        collect(in: el, limit: 8, into: &found) { role($0) == kAXStaticTextRole }
        var result: [String] = []
        for t in found {
            let v = (attr(t, kAXValueAttribute) as? String) ?? str(t, kAXTitleAttribute)
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }

    // MARK: Public entry point

    /// Opens Music.app's Up Next popover, scrapes it, and closes it again.
    /// Must be called off the main thread.
    static func read(openIfNeeded: Bool = false) throws -> [UpNextRow] {
        guard isTrusted else { throw ReadError.notTrusted }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: MusicBridge.bundleID).first
        else { throw ReadError.notRunning }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        guard let button = find(in: axApp, limit: 18, { el in
            let r = role(el)
            guard r == kAXButtonRole || r == kAXMenuButtonRole || r == "AXToggleButton" else { return false }
            return matchesUpNext(labelBlob(el))
        }) else { throw ReadError.buttonNotFound }

        func lists() -> [AXUIElement] {
            var result: [AXUIElement] = []
            collect(in: axApp, limit: 24, into: &result) {
                [kAXTableRole, kAXOutlineRole, kAXListRole].contains(role($0))
            }
            return result
        }
        func labelledList() -> AXUIElement? {
            find(in: axApp, limit: 24) { el in
                guard matchesUpNext(labelBlob(el)) else { return false }
                return [kAXTableRole, kAXOutlineRole, kAXListRole].contains(role(el))
            }
        }

        let before = lists()
        var target = labelledList()
        var opened = false
        defer {
            if opened { AXUIElementPerformAction(button, kAXPressAction as CFString) }
        }
        if target == nil {
            guard openIfNeeded else { throw ReadError.listNotFound }
            // Do not choose an arbitrary library table: only a labelled queue
            // or a uniquely identifiable list that appeared after opening it.
            let alreadyOpen = (attr(button, kAXValueAttribute) as? NSNumber)?.boolValue == true
            guard !alreadyOpen else { throw ReadError.listNotFound }
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                throw ReadError.buttonNotFound
            }
            opened = true
            Thread.sleep(forTimeInterval: 0.55)
            target = labelledList()
            if target == nil {
                let fresh = lists().filter { candidate in !before.contains { CFEqual($0, candidate) } }
                if fresh.count == 1 { target = fresh.first }
            }
        }
        guard let target else { throw ReadError.listNotFound }
        var rows: [AXUIElement] = []
        collect(in: target, limit: 6, into: &rows) { role($0) == kAXRowRole }
        if rows.isEmpty {
            rows = children(target).filter { [kAXGroupRole, kAXCellRole].contains(role($0)) }
        }
        var result: [UpNextRow] = []
        for row in rows.prefix(200) {
            let parts = texts(of: row)
            guard !parts.isEmpty else { continue }
            let title = parts[0]
            let subtitle = parts.dropFirst().prefix(2).joined(separator: " — ")
            result.append(UpNextRow(title: title, subtitle: subtitle))
        }

        return result
    }
}
