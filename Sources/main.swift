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
    private static let scrollInterval: TimeInterval = 0.28

    /// Reserve exactly what the window needs rather than guessing a constant:
    /// measured against full-width glyphs so a Japanese title fits, and only
    /// while something is actually scrolling.
    private static var scrollingItemWidth: CGFloat {
        let sample = " " + String(repeating: "あ", count: titleWidth)
        let measured = (sample as NSString).size(withAttributes: [.font: titleFont]).width
        // Room for the icon and the button's own padding.
        return ceil(measured) + 30
    }

    private var marqueeTimer: Timer?
    private var marqueeStep = 0
    private var marqueeText = ""
    private var marqueeIsPlaying = false

    private func setMarquee(text: String, playing: Bool) {
        if text != marqueeText {
            marqueeText = text
            marqueeStep = 0
        }
        marqueeIsPlaying = playing
        let needsScroll = playing && Marquee.scrolls(text, width: Self.titleWidth)
        if needsScroll {
            if marqueeTimer == nil {
                let timer = Timer(timeInterval: Self.scrollInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.advanceMarquee() }
                }
                // Common mode so the ticker keeps moving while a menu is open.
                RunLoop.main.add(timer, forMode: .common)
                marqueeTimer = timer
            }
        } else {
            marqueeTimer?.invalidate()
            marqueeTimer = nil
        }
        renderMarquee()
    }

    private func advanceMarquee() {
        marqueeStep += 1
        renderMarquee()
    }

    private func renderMarquee() {
        guard let button = statusItem?.button else { return }
        let scrolling = marqueeIsPlaying && Marquee.scrolls(marqueeText, width: Self.titleWidth)
        let visible = scrolling
            ? Marquee.window(marqueeText, width: Self.titleWidth, step: marqueeStep)
            : Marquee.parked(marqueeText, width: Self.titleWidth)
        // A title that fits takes only the space it needs; a scrolling one gets
        // a fixed width so the items beside it do not shuffle on every frame.
        statusItem.length = scrolling ? Self.scrollingItemWidth : NSStatusItem.variableLength
        button.attributedTitle = NSAttributedString(string: " " + visible, attributes: [
            .font: Self.titleFont,
            .foregroundColor: marqueeIsPlaying ? NSColor.labelColor : NSColor.secondaryLabelColor
        ])
    }

    private func updateStatusTitle(_ snapshot: NowPlaying) {
        guard let button = statusItem?.button else { return }
        guard let track = snapshot.track, snapshot.state != .stopped else {
            marqueeTimer?.invalidate()
            marqueeTimer = nil
            marqueeText = ""
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
        mediaKeys.stop()
        marqueeTimer?.invalidate()
        marqueeTimer = nil
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
