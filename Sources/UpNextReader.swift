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
    // Reading the queue and adding a playlist both touch Music's UI. Do not
    // allow an automatic refresh to close a menu while an addition is pending.
    private static let accessQueue = DispatchQueue(label: "jp.menuqueue.music-ui")


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
        for child in children(el).reversed() {
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
        collect(in: el, limit: 8, into: &found) {
            [kAXStaticTextRole, kAXTextAreaRole, "AXText"].contains(role($0))
        }
        var result: [String] = []
        for t in found {
            let v = (attr(t, kAXValueAttribute) as? String)
                ?? (attr(t, kAXValueAttribute) as? NSAttributedString)?.string
                ?? [str(t, kAXTitleAttribute), str(t, kAXDescriptionAttribute)].first(where: { !$0.isEmpty }) ?? ""
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }

    // MARK: Public entry point

    /// Opens Music.app's Up Next popover, scrapes it, and closes it again.
    /// Must be called off the main thread.
    static func read(openIfNeeded: Bool = false) throws -> [UpNextRow] {
        try accessQueue.sync { try readImpl(openIfNeeded: openIfNeeded) }
    }

    private static func readImpl(openIfNeeded: Bool) throws -> [UpNextRow] {
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
            func visit(_ element: AXUIElement, depth: Int) {
                guard depth < 18 else { return }
                let r = role(element)
                if [kAXTableRole, kAXOutlineRole, kAXListRole].contains(r) {
                    result.append(element)
                    return
                }
                if r == "AXCollection" { return }
                for child in children(element) { visit(child, depth: depth + 1) }
            }
            visit(axApp, depth: 0)
            return result
        }
        func labelledList() -> AXUIElement? {
            if let labelled = find(in: axApp, limit: 24, { el in
                matchesUpNext(labelBlob(el)) &&
                [kAXTableRole, kAXOutlineRole, kAXListRole].contains(role(el))
            }) { return labelled }
            // Current Music labels the surrounding container "再生キュー";
            // its table itself has no label.
            guard let region = find(in: axApp, limit: 24, { el in
                str(el, kAXIdentifierAttribute) == "headerContainer" && matchesUpNext(labelBlob(el))
            }) else { return nil }
            return find(in: region, limit: 6) { [kAXTableRole, kAXListRole].contains(role($0)) }
        }

        var target = labelledList()
        let before = target == nil ? lists() : []
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
        var inHistory = false
        for row in rows.prefix(500) {
            let parts = texts(of: row)
            guard !parts.isEmpty else { continue }
            let title = parts[0].replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title == "履歴" || title.lowercased() == "history" { inHistory = true; continue }
            let hasTrackMenu = find(in: row, limit: 5) {
                str($0, kAXIdentifierAttribute) == "actionButton"
            } != nil
            if !hasTrackMenu && (matchesUpNext(title.lowercased()) || title.localizedCaseInsensitiveContains("autoplay") || title.contains("自動再生")) {
                inHistory = false
                continue
            }
            if inHistory { continue }
            let subtitle = parts.dropFirst().prefix(2).joined(separator: " — ")
            result.append(UpNextRow(title: title, subtitle: subtitle))
        }

        return result
    }
}


extension UpNextReader {
    enum AddError: LocalizedError {
        case playlistNotShown, menuUnavailable, queueActionUnavailable, actionFailed
        var errorDescription: String? {
            switch self {
            case .playlistNotShown: return "追加するプレイリストをMusicで確認できませんでした"
            case .menuUnavailable: return "Musicのプレイリスト操作メニューを開けませんでした"
            case .queueActionUnavailable: return "Musicでキューへの追加を利用できません。曲を再生してから試してください"
            case .actionFailed: return "キューへの追加操作に失敗しました"
            }
        }
    }

    static func enqueuePlaylist(_ persistentID: String) throws -> QueueInsertionPosition {
        try accessQueue.sync {
            guard isTrusted else { throw ReadError.notTrusted }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: MusicBridge.bundleID).first
            else { throw ReadError.notRunning }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            // Identify the playlist by its persistent ID, never an ambiguous name.
            try MusicBridge.revealPlaylist(persistentID)
            var more: AXUIElement?
            for _ in 0..<20 {
                if (try? MusicBridge.displayedPlaylistID()) == persistentID {
                    if let toolbar = find(in: axApp, limit: 8, { role($0) == kAXToolbarRole }) {
                        more = find(in: toolbar, limit: 5) { str($0, kAXIdentifierAttribute) == "moreBtn" }
                    }
                    if more != nil { break }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard (try? MusicBridge.displayedPlaylistID()) == persistentID else { throw AddError.playlistNotShown }
            guard let more, AXUIElementPerformAction(more, kAXPressAction as CFString) == .success
            else { throw AddError.menuUnavailable }

            var menu: AXUIElement?
            for _ in 0..<15 {
                menu = find(in: axApp, limit: 8) { role($0) == kAXMenuRole }
                if menu != nil { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard let menu else { throw AddError.menuUnavailable }
            defer { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
            guard (try? MusicBridge.displayedPlaylistID()) == persistentID else { throw AddError.playlistNotShown }
            let options = children(menu).filter {
                role($0) == kAXMenuItemRole && (attr($0, kAXEnabledAttribute) as? Bool) != false
            }
            let titles = options.map { str($0, kAXTitleAttribute) }
            guard let choice = QueueInsertionPosition.menuChoice(titles) else { throw AddError.queueActionUnavailable }
            guard AXUIElementPerformAction(options[choice.index], kAXPressAction as CFString) == .success
            else { throw AddError.actionFailed }
            return choice.position
        }
    }
}
