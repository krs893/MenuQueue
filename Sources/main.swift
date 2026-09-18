import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store: QueueStore!
    private var player: PlayerController!
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = QueueStore()
        player = PlayerController(store: store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "MenuQueue")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 390, height: 600)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(player: player, store: store)
        )

        player.$now
            .receive(on: RunLoop.main)
            .sink { [weak self] np in self?.updateTitle(np) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        player?.shutdown()
    }

    private func updateTitle(_ np: NowPlaying) {
        guard let button = statusItem.button else { return }
        guard np.state.isPlaying || np.state == .paused, let track = np.track else {
            button.title = ""
            return
        }
        var label = track.name
        if !track.artist.isEmpty { label += " — " + track.artist }
        if label.count > 30 { label = String(label.prefix(29)) + "…" }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: np.state == .paused ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        button.attributedTitle = NSAttributedString(string: " " + label, attributes: attrs)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: player.now.state.isPlaying ? "一時停止" : "再生",
                     action: #selector(menuPlayPause), keyEquivalent: "")
        menu.addItem(withTitle: "次の曲", action: #selector(menuNext), keyEquivalent: "")
        menu.addItem(withTitle: "前の曲", action: #selector(menuPrev), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "ミュージックを開く", action: #selector(menuOpenMusic), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "MenuQueue を終了", action: #selector(menuQuit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuPlayPause() { player.togglePlayPause() }
    @objc private func menuNext() { player.next() }
    @objc private func menuPrev() { player.previous() }
    @objc private func menuOpenMusic() { player.launchMusic() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await player.tick() }
        }
    }
}

// Headless helpers so the login item can be toggled from a script as well as
// from the settings panel.
if CommandLine.arguments.contains("--register-login-item") {
    if let err = LoginItem.set(true) { FileHandle.standardError.write(Data(err.utf8)); exit(1) }
    print("login item: \(LoginItem.statusText)")
    exit(0)
}
if CommandLine.arguments.contains("--unregister-login-item") {
    if let err = LoginItem.set(false) { FileHandle.standardError.write(Data(err.utf8)); exit(1) }
    print("login item: \(LoginItem.statusText)")
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
