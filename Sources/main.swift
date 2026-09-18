import AppKit
import SwiftUI

@MainActor
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Placement is already clamped to the clicked display. AppKit must not
    // constrain this to an unrelated key window's screen during tab changes.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var menuPanel: MenuPanel!
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var store: QueueStore!
    private var player: PlayerController!
    private var playerWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = QueueStore()
        player = PlayerController(store: store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "MenuQueue")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menuPanel = MenuPanel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        menuPanel.title = "MenuQueue"
        menuPanel.isFloatingPanel = true
        menuPanel.level = .popUpMenu
        menuPanel.hidesOnDeactivate = false
        menuPanel.isMovable = false
        menuPanel.isReleasedWhenClosed = false
        menuPanel.hasShadow = true
        menuPanel.isOpaque = false
        menuPanel.backgroundColor = .clear
        menuPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let panelContent = NSHostingView(rootView:
            ContentView(player: player, store: store)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12)))
        panelContent.sizingOptions = []
        panelContent.autoresizingMask = [.width, .height]
        menuPanel.contentView = panelContent
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        if CommandLine.arguments.contains("--window") { showPlayerWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dismissPanel()
        NotificationCenter.default.removeObserver(self)
        player?.shutdown()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePanel(sender)
        }
    }

    private func showContextMenu() {
        dismissPanel()
        let menu = NSMenu()
        menu.addItem(withTitle: player.now.state.isPlaying ? "一時停止" : "再生",
                     action: #selector(menuPlayPause), keyEquivalent: "")
        menu.addItem(withTitle: "次の曲", action: #selector(menuNext), keyEquivalent: "")
        menu.addItem(withTitle: "前の曲", action: #selector(menuPrev), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "ウインドウで開く", action: #selector(showPlayerWindow), keyEquivalent: "")
        menu.addItem(withTitle: "ミュージックを開く", action: #selector(menuOpenMusic), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "MenuQueue を終了", action: #selector(menuQuit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showPlayerWindow() {
        dismissPanel()
        if playerWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "MenuQueue"
            window.contentView = NSHostingView(rootView: ContentView(player: player, store: store))
            window.minSize = NSSize(width: 440, height: 690)
            window.isReleasedWhenClosed = false
            window.center()
            playerWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        playerWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func menuPlayPause() { player.togglePlayPause() }
    @objc private func menuNext() { player.next() }
    @objc private func menuPrev() { player.previous() }
    @objc private func menuOpenMusic() { player.launchMusic() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func displaysChanged() {
        // On display disconnect/resolution changes, reopen from the next click
        // instead of letting the system move an existing panel to another screen.
        dismissPanel()
    }

    private func dismissPanel() {
        menuPanel?.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }

    private func togglePanel(_ sender: NSStatusBarButton) {
        let click = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(click) }) else { return }
        if menuPanel.isVisible && screen.frame.contains(menuPanel.frame.origin) {
            dismissPanel()
            return
        }
        dismissPanel()
        let buttonRect = sender.window.map { $0.convertToScreen(sender.convert(sender.bounds, to: nil)) }
        let frame = PanelPlacement.frame(click: click, button: buttonRect,
                                         screen: screen.frame, visible: screen.visibleFrame)
        menuPanel.setFrame(frame, display: false)
        menuPanel.makeKeyAndOrderFront(nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
            [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismissPanel(); return nil }
            } else if event.window !== self.menuPanel && event.window !== self.statusItem.button?.window {
                self.dismissPanel()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in self?.dismissPanel() }
        }
        Task { await player.tick() }
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
