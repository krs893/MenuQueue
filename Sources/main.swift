import AppKit
import SwiftUI
import Combine

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
    private var cancellables = Set<AnyCancellable>()
    private let mediaKeys = MediaKeyTap()
    private var stallWatch: Timer?
    private static let stallMessage = "ミュージックからの応答が止まっています。メニューバーを右クリックして MenuQueue を終了し、開き直してください"

    private func checkForStall() {
        let stalled = ScriptRunner.shared.stalledSeconds > 20
        if stalled, player.lastError != Self.stallMessage {
            player.lastError = Self.stallMessage
        } else if !stalled, player.lastError == Self.stallMessage {
            player.lastError = nil
        }
    }

    /// Menu bar space is shared with every other app — the user wants room for
    /// other status items — so the width is a constant and long titles scroll
    /// through it. Only the track name goes up there; artist and album stay in
    /// the tooltip and in the panel.
    /// Characters visible at once. Deliberately small: every point taken here
    /// is a point unavailable to the other status items sharing the menu bar.
    /// Override with `defaults write jp.local.menuqueue menuBarTitleWidth -int N`.
    private static var titleWidth: Int {
        let configured = UserDefaults.standard.integer(forKey: "menuBarTitleWidth")
        return configured > 0 ? min(configured, 40) : 10
    }
    private static let titleFont = NSFont.systemFont(ofSize: 12)

    private let ticker = TickerView(frame: .zero)
    private var marqueeText = ""
    private var marqueeIsPlaying = false
    /// What is on screen now. The player publishes a snapshot on every poll,
    /// and restarting the ticker for each one would snap it back to the start
    /// every second, so only a change of title or of playing state counts.
    private var renderedMarquee: String?

    private func setMarquee(text: String, playing: Bool) {
        let key = "\(playing)|\(text)"
        guard key != renderedMarquee else { return }
        renderedMarquee = key
        marqueeText = text
        marqueeIsPlaying = playing
        renderMarquee()
    }

    private func clearMarquee() {
        renderedMarquee = nil
        marqueeText = ""
        ticker.stop()
        ticker.removeFromSuperview()
    }

    private func renderMarquee() {
        guard let button = statusItem?.button else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scrolling = marqueeIsPlaying && !reduceMotion
            && Marquee.scrolls(marqueeText, width: Self.titleWidth)
        statusItem.length = NSStatusItem.variableLength
        button.setAccessibilityTitle(marqueeText)

        guard scrolling else {
            ticker.stop()
            ticker.removeFromSuperview()
            let visible = Marquee.parked(marqueeText, width: Self.titleWidth)
            button.attributedTitle = NSAttributedString(string: " " + visible, attributes: [
                .font: Self.titleFont,
                .foregroundColor: marqueeIsPlaying ? NSColor.labelColor : NSColor.secondaryLabelColor
            ])
            return
        }

        // An invisible stand-in of fixed width reserves the room, so the item
        // keeps a constant size and the icon stays drawn by AppKit; the ticker
        // then scrolls over exactly the space the title would occupy.
        let room = " " + String(repeating: "あ", count: Self.titleWidth)
        button.attributedTitle = NSAttributedString(string: room, attributes: [
            .font: Self.titleFont, .foregroundColor: NSColor.clear
        ])
        if ticker.superview !== button { button.addSubview(ticker) }
        positionTicker()
        ticker.show(marqueeText, font: Self.titleFont)
    }

    /// Puts the ticker exactly over the space the title would take. Called
    /// again whenever the button is resized: the menu bar settles an item's
    /// width after the title changes, and a ticker placed against the old
    /// bounds would sit in the wrong spot until the next song.
    private func positionTicker() {
        guard let button = statusItem?.button, ticker.superview === button else { return }
        button.layoutSubtreeIfNeeded()
        var rect = button.cell?.titleRect(forBounds: button.bounds) ?? button.bounds
        // Start where a static title's first character would, after its space.
        let space = ceil((" " as NSString).size(withAttributes: [.font: Self.titleFont]).width)
        rect.origin.x += space
        rect.size.width -= space
        let target = rect.integral
        if ticker.frame != target { ticker.frame = target }
    }

    private func updateStatusTitle(_ snapshot: NowPlaying) {
        guard let button = statusItem?.button else { return }
        guard let track = snapshot.track, snapshot.state != .stopped else {
            clearMarquee()
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
            button.toolTip = "MenuQueue"
            return
        }

        button.imagePosition = .imageLeading
        // A paused track stays readable but recedes, and stops scrolling.
        setMarquee(text: track.name, playing: snapshot.state.isPlaying)
        button.toolTip = [track.name, track.artist, track.album]
            .filter { !$0.isEmpty }.joined(separator: " — ")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = QueueStore()
        player = PlayerController(store: store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "MenuQueue")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if let button = statusItem.button {
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                   object: button, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.positionTicker() }
            }
        }

        // A call into Music that never comes back cannot be cancelled, but it
        // must not be left looking like a slow load. Say what happened.
        stallWatch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForStall() }
        }

        // Next / previous on the keyboard walk this app's queue while it is in
        // charge; otherwise the keys go to Music as usual.
        mediaKeys.shouldIntercept = { [weak self] in self?.player.owns ?? false }
        mediaKeys.onNext = { [weak self] in self?.player.next() }
        mediaKeys.onPrevious = { [weak self] in self?.player.previous() }
        mediaKeys.start()

        // Keep the menu bar showing whatever is playing.
        player.$now
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.updateStatusTitle(snapshot) }
            .store(in: &cancellables)

        // And show it as a Discord activity while it plays.
        player.$now
            .sink { DiscordPresence.shared.update($0) }
            .store(in: &cancellables)

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
        if CommandLine.arguments.contains("--resume-queue") {
            Task { await player.resumeCurrentQueue() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPlayerWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiscordPresence.shared.shutdown()
        mediaKeys.stop()
        clearMarquee()
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
        player.refreshNativeQueue()
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
