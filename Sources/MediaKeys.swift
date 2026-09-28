import AppKit
import ApplicationServices

/// The media keys the tap cares about, as they arrive in a system-defined
/// event: subtype 8, with the key and its state packed into `data1`.
enum MediaKey: Int {
    case playPause = 16   // NX_KEYTYPE_PLAY
    case next = 17        // NX_KEYTYPE_NEXT
    case previous = 18    // NX_KEYTYPE_PREVIOUS
    case fast = 19        // NX_KEYTYPE_FAST   — some keyboards send this for next
    case rewind = 20      // NX_KEYTYPE_REWIND — and this for previous

    struct Press: Equatable {
        var key: MediaKey
        var isDown: Bool
        var isRepeat: Bool
    }

    /// Unpacks `data1` of an NX_SYSDEFINED / subtype 8 event. Pure, so the bit
    /// layout is tested without synthesising real events.
    static func decode(data1: Int) -> Press? {
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0x0000_FFFF
        guard let key = MediaKey(rawValue: code) else { return nil }
        let state = (flags & 0xFF00) >> 8
        return Press(key: key, isDown: state == 0x0A, isRepeat: (flags & 0x1) != 0)
    }

    /// Next and previous both have two spellings depending on the keyboard.
    var isNext: Bool { self == .next || self == .fast }
    var isPrevious: Bool { self == .previous || self == .rewind }
}

/// Catches next / previous on the media keys while this app's queue is
/// driving playback, before Music sees them.
///
/// Music would otherwise act on them itself — and since the queue hands Music
/// one track at a time, Music has no "next": it just restarts the song. When
/// the queue is not in charge the keys pass through untouched, so Music behaves
/// exactly as it always does.
///
/// Swallowing keys needs an active event tap, which macOS only grants with the
/// Accessibility permission. Without it the tap cannot be created; the app
/// keeps retrying so that granting the permission takes effect without a
/// relaunch.
@MainActor
final class MediaKeyTap {

    /// Asked on every key: should the queue handle this rather than Music?
    var shouldIntercept: () -> Bool = { false }
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}

    private(set) var isActive = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?

    /// NX_SYSDEFINED — not importable into Swift under that name.
    private static let systemDefined = CGEventType(rawValue: 14)!

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func start() {
        guard tap == nil else { return }
        if install() { return }
        // Not permitted yet. Keep trying quietly, so granting Accessibility in
        // System Settings starts working without restarting the app.
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.install() {
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                }
            }
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isActive = false
    }

    private func install() -> Bool {
        guard Self.isTrusted else { return false }
        let mask = CGEventMask(1 << Self.systemDefined.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: mediaKeyCallback,
                                           userInfo: refcon)
        else { return false }
        let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        // On the main run loop, so the callback runs on the main thread and can
        // consult the player directly.
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = loopSource
        isActive = true
        return true
    }

    /// Returns nil to swallow the event, or the event to let it through.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a tap off if a callback is ever slow; switch it back.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == Self.systemDefined,
              let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == 8,
              let press = MediaKey.decode(data1: ns.data1),
              press.key.isNext || press.key.isPrevious,
              shouldIntercept()
        else { return Unmanaged.passUnretained(event) }

        // Act once per press; swallow the key-up and auto-repeat too, or Music
        // would still see half of the gesture.
        if press.isDown && !press.isRepeat {
            if press.key.isNext { onNext() } else { onPrevious() }
        }
        return nil
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    // The run loop source is on the main run loop, so this is the main thread.
    return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
}
