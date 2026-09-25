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
        var result = (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        guard role(el) == kAXApplicationRole else { return result }
        // Music's application element exposes only its menu bar under
        // AXChildren, and AXWindows comes back empty (observed on macOS 26:
        // err=0, array(0) while a window is on screen). The player window is
        // reachable only through AXMainWindow / AXFocusedWindow, so splice
        // those in — otherwise every traversal that starts at the app element
        // stops at the menu bar and the queue button is never found.
        for name in [kAXWindowsAttribute, kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            guard let value = attr(el, name) else { continue }
            let found: [AXUIElement]
            if let array = value as? [AXUIElement] {
                found = array
            } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
                found = [(value as! AXUIElement)]
            } else {
                continue
            }
            for candidate in found {
                // AXFocusedWindow answers with the application element itself
                // when no window holds focus. Splicing that back in makes the
                // app its own descendant: the walk then loops until it runs
                // out of depth and never reaches the real window, which looks
                // exactly like the queue button having disappeared.
                guard role(candidate) == kAXWindowRole else { continue }
                guard !CFEqual(candidate, el) else { continue }
                guard !result.contains(where: { CFEqual($0, candidate) }) else { continue }
                result.append(candidate)
            }
        }
        return result
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
            if let value = QueueTextParser.firstText([
                attr(t, kAXValueAttribute) as? String,
                (attr(t, kAXValueAttribute) as? NSAttributedString)?.string,
                str(t, kAXTitleAttribute), str(t, kAXDescriptionAttribute)
            ]) { result.append(value) }
        }
        return result
    }

    /// Roles whose subtree holds browsed content, never player chrome.
    ///
    /// Walking them is what made a read take half a minute: with a playlist on
    /// screen the content area alone is ~900 elements and every child query is
    /// a synchronous cross-process call, measured at 4.4s for one pass while
    /// the whole tree is only ~1200 nodes. The queue button lives in the mini
    /// player group at depth 6, so none of that is worth visiting.
    /// One IPC round trip per element instead of one per attribute.
    ///
    /// Every AXUIElementCopyAttributeValue is a synchronous call into Music.
    /// Walking 143 queue rows twice — once for their text, once to check for
    /// the row menu — cost 3.7s; fetching the attributes together in a single
    /// pass brings the same result back in 0.77s.
    private static let nodeAttributes = [
        kAXRoleAttribute, kAXIdentifierAttribute, kAXValueAttribute,
        kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute
    ] as CFArray

    private struct Node {
        var role = ""
        var identifier = ""
        var value: Any?
        var title = ""
        var desc = ""
        var children: [AXUIElement] = []
    }

    private static func node(_ el: AXUIElement) -> Node {
        var raw: CFArray?
        var n = Node()
        guard AXUIElementCopyMultipleAttributeValues(el, nodeAttributes, AXCopyMultipleAttributeOptions(), &raw) == .success,
              let values = raw as? [Any], values.count >= 6
        else { return n }
        func string(_ i: Int) -> String { values[i] as? String ?? "" }
        n.role = string(0)
        n.identifier = string(1)
        n.value = values[2]
        n.title = string(3)
        n.desc = string(4)
        n.children = (values[5] as? [AXUIElement]) ?? []
        return n
    }

    /// Collects a row's text and whether it carries a track menu in a single
    /// traversal — the menu is what tells a real queue entry from a section
    /// heading, so both answers are needed for every row.
    private static func parseRow(_ row: AXUIElement) -> QueueTextParser.Row {
        var texts: [String] = []
        var hasTrackMenu = false
        func visit(_ el: AXUIElement, _ depth: Int) {
            guard depth <= 6 else { return }
            let n = node(el)
            if n.identifier == "actionButton" { hasTrackMenu = true }
            if [kAXStaticTextRole, kAXTextAreaRole, "AXText"].contains(n.role) {
                if let text = QueueTextParser.firstText([
                    n.value as? String,
                    (n.value as? NSAttributedString)?.string,
                    n.title, n.desc
                ]) { texts.append(text) }
            }
            for child in n.children { visit(child, depth + 1) }
        }
        visit(row, 0)
        return QueueTextParser.Row(texts: texts, hasTrackMenu: hasTrackMenu)
    }

    private static let contentRoles: Set<String> = [
        kAXTableRole, kAXOutlineRole, kAXListRole, kAXScrollAreaRole, "AXCollection"
    ]

    private static func rowCount(of list: AXUIElement) -> Int {
        children(list).reduce(0) { $0 + (role($1) == kAXRowRole ? 1 : 0) }
    }

    private static var cachedButton: AXUIElement?

    /// Music exposes the control as `Music.miniPlayer.queueButton`; the
    /// identifier is stable across languages, unlike its 「次に再生」 label.
    private static func queueButton(in axApp: AXUIElement) -> AXUIElement? {
        if let cached = cachedButton, !labelBlob(cached).isEmpty { return cached }
        cachedButton = nil

        var result: AXUIElement?
        func visit(_ el: AXUIElement, _ depth: Int) {
            guard depth <= 10, result == nil else { return }
            let r = role(el)
            guard !contentRoles.contains(r) else { return }
            if r == kAXButtonRole || r == kAXMenuButtonRole || r == "AXToggleButton" {
                if matchesUpNext(labelBlob(el)) { result = el; return }
            }
            for child in children(el) { visit(child, depth + 1) }
        }
        visit(axApp, 0)
        cachedButton = result
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

        guard let button = queueButton(in: axApp) else { throw ReadError.buttonNotFound }

        // One traversal answers every question below. The previous shape ran
        // `lists()` and two `find(in: axApp,)` sweeps, then repeated all of
        // them after opening the popover — five-plus full passes over a tree
        // that costs seconds each time.
        struct Survey {
            var lists: [AXUIElement] = []
            var labelled: AXUIElement?
            var headerRegion: AXUIElement?
        }
        func survey() -> Survey {
            var out = Survey()
            func visit(_ element: AXUIElement, depth: Int) {
                guard depth < 18 else { return }
                let r = role(element)
                if r == "AXCollection" { return }
                let isList = [kAXTableRole, kAXOutlineRole, kAXListRole].contains(r)
                if isList {
                    out.lists.append(element)
                    if out.labelled == nil, matchesUpNext(labelBlob(element)) { out.labelled = element }
                    return
                }
                if out.headerRegion == nil,
                   str(element, kAXIdentifierAttribute) == "headerContainer",
                   matchesUpNext(labelBlob(element)) {
                    out.headerRegion = element
                }
                for child in children(element) { visit(child, depth: depth + 1) }
            }
            visit(axApp, depth: 0)
            return out
        }
        /// The queue table has no label and no identifier; what marks it is
        /// that its rows carry the per-track action menu. Used only to tell
        /// whether the popover is currently on screen.
        func queueTable(_ s: Survey) -> AXUIElement? {
            for list in s.lists where role(list) != kAXOutlineRole {
                let rows = children(list).filter { role($0) == kAXRowRole }
                guard !rows.isEmpty else { continue }
                let hasMenus = rows.prefix(3).contains { row in
                    find(in: row, limit: 5) { str($0, kAXIdentifierAttribute) == "actionButton" } != nil
                }
                if hasMenus { return list }
            }
            return nil
        }
        func queueList(_ s: Survey) -> AXUIElement? {
            if let labelled = s.labelled { return labelled }
            // Current Music labels the surrounding container "再生キュー";
            // its table itself has no label.
            guard let region = s.headerRegion else { return nil }
            return find(in: region, limit: 6) { [kAXTableRole, kAXListRole].contains(role($0)) }
        }

        var scan = survey()
        // A queue list with no rows is the popover Music is still tearing down
        // after the previous read closed it. Accepting it returned an empty
        // queue on every other refresh, so treat it as not found and reopen.
        var target = queueList(scan).flatMap { rowCount(of: $0) > 0 ? $0 : nil }
        let before = target == nil ? scan.lists : []
        var opened = false
        func closePopover() {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            // Music's queue table carries no label and its button reports no
            // open/closed state, so the only way to recognise the queue is
            // "the list that appeared after pressing". That only holds if the
            // popover is actually shut by the time the next read starts —
            // otherwise the next read finds nothing new and comes back empty,
            // which showed as the queue alternating between full and blank.
            let closeBy = Date().addingTimeInterval(1.5)
            repeat {
                Thread.sleep(forTimeInterval: 0.05)
                if queueTable(survey()) == nil { return }
            } while Date() < closeBy
        }
        defer { if opened { closePopover() } }
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
            // Music fills the popover asynchronously. A fixed wait was
            // sometimes shorter than that, and the read then returned an empty
            // queue — visible as the list alternating between full and blank
            // on repeated refreshes. Poll until rows show up instead.
            let deadline = Date().addingTimeInterval(2.5)
            var lastRowCount = -1
            repeat {
                Thread.sleep(forTimeInterval: 0.05)
                scan = survey()
                target = queueList(scan)
                if target == nil {
                    let fresh = scan.lists.filter { candidate in !before.contains { CFEqual($0, candidate) } }
                    if fresh.count == 1 { target = fresh.first }
                }
                // Reading while Music is still filling the popover returned a
                // partial list (66 of 143 rows) whose visible section was all
                // history, so the queue came back empty. Wait for the count to
                // stop growing before trusting it.
                if let found = target {
                    let count = rowCount(of: found)
                    if count > 0, count == lastRowCount { break }
                    lastRowCount = count
                }
            } while Date() < deadline
        }
        guard let target else { throw ReadError.listNotFound }
        // Rows are direct children of the table. The generic collector kept
        // descending into each one looking for more rows, which walked all 143
        // subtrees and cost 2.5s of a 4s read — longer than everything else
        // combined. Take the children directly and only fall back to a search
        // that stops at the first row of each branch.
        var rows = children(target).filter { role($0) == kAXRowRole }
        if rows.isEmpty {
            func gather(_ el: AXUIElement, _ depth: Int) {
                guard depth <= 6 else { return }
                if role(el) == kAXRowRole { rows.append(el); return }
                for child in children(el) { gather(child, depth + 1) }
            }
            gather(target, 0)
        }
        if rows.isEmpty {
            rows = children(target).filter { [kAXGroupRole, kAXCellRole].contains(role($0)) }
        }
        let parsed = rows.prefix(2000).map(parseRow)
        return QueueTextParser.upcoming(parsed).map { UpNextRow(title: $0.title, subtitle: $0.subtitle) }

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
            // `reveal` is the only way to put a playlist on screen so its
            // toolbar menu can be driven, and it brings Music to the front.
            // Adding to the queue from a menu bar app should not steal the
            // screen, so put the previous app back when we are done.
            let previousApp = NSWorkspace.shared.frontmostApplication
            defer {
                if let previousApp, previousApp.bundleIdentifier != MusicBridge.bundleID {
                    previousApp.activate()
                }
            }
            // `reveal` only actually switches the browser view when Music is
            // the active app — without this the view never changes, the check
            // below times out, and adding to the queue fails for no visible
            // reason. Activate deliberately, then hand the screen back.
            app.activate()
            Thread.sleep(forTimeInterval: 0.15)
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
                Thread.sleep(forTimeInterval: 0.05)
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
