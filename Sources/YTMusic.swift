import Foundation
import AppKit

// MARK: - Model

struct YTQueueItem: Equatable, Identifiable {
    var id: Int { index }
    var index: Int
    var title: String
    var artist: String
    var duration: String
    var thumbnail: URL?
}

struct YTState: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var artwork: URL?
    var playing = false
    var position: Double = 0
    var duration: Double = 0
    /// YouTube Music's own volume slider, 0...100 (not the media element's
    /// gain, which it maps onto a curve).
    var volume = 0
    var muted = false
    /// off / all / one
    var repeatMode = "off"
    var queue: [YTQueueItem] = []
    var currentIndex: Int?

    var hasTrack: Bool { !title.isEmpty }
}

// MARK: - Parsing (pure, tested)

enum YTPayload {
    /// The player bar's byline reads "Artist • Album • Year" for songs and
    /// "Artist • 1.2M views • …" for videos; only a three-part byline whose
    /// last part is a year names an album.
    static func splitByline(_ byline: String) -> (artist: String, album: String) {
        let parts = byline.components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let artist = parts.first else { return ("", "") }
        if parts.count >= 3, let last = parts.last, last.count == 4, Int(last) != nil {
            return (artist, parts[1])
        }
        return (artist, "")
    }

    /// Thumbnails come at 60 px; Discord and the panel header want more. The
    /// size is in the URL ("=w60-h60-…"), so ask for a bigger one.
    static func enlarge(_ url: String, to side: Int) -> URL? {
        guard url.hasPrefix("http") else { return nil }   // data: placeholders
        let resized = url.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w\(side)-h\(side)",
                                               options: .regularExpression)
        return URL(string: resized)
    }

    static func parse(_ json: String) -> YTState? {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["ok"] as? Bool) == true
        else { return nil }
        var s = YTState()
        s.title = o["title"] as? String ?? ""
        let byline = splitByline(o["byline"] as? String ?? "")
        s.artist = byline.artist
        s.album = byline.album
        s.artwork = enlarge(o["artwork"] as? String ?? "", to: 544)
        s.playing = o["playing"] as? Bool ?? false
        s.position = finite(o["position"])
        s.duration = finite(o["duration"])
        s.volume = Int(finite(o["volume"]))
        s.muted = o["muted"] as? Bool ?? false
        let repeatLabel = (o["repeat"] as? String ?? "").lowercased()
        s.repeatMode = repeatLabel.contains("one") ? "one" : repeatLabel.contains("all") ? "all" : "off"
        let items = o["queue"] as? [[String: Any]] ?? []
        s.queue = items.enumerated().map { i, it in
            YTQueueItem(index: i,
                        title: it["title"] as? String ?? "",
                        artist: it["artist"] as? String ?? "",
                        duration: it["duration"] as? String ?? "",
                        thumbnail: enlarge(it["thumb"] as? String ?? "", to: 120))
        }
        if let current = o["current"] as? Int, current >= 0, current < s.queue.count { s.currentIndex = current }
        return s
    }

    private static func finite(_ any: Any?) -> Double {
        guard let d = (any as? NSNumber)?.doubleValue, d.isFinite else { return 0 }
        return max(d, 0)
    }
}

// MARK: - Bridge

/// Drives YouTube Music running as a Chrome tab or installed Chrome app.
///
/// Scripts run through Chrome's AppleScript `execute javascript`, which needs
/// Chrome's "Allow JavaScript from Apple Events" setting. They run in an
/// isolated world: the page's own JavaScript (its player API) is out of reach,
/// and Trusted Types refuses injected scripts, but the DOM is shared. So state
/// is read from the player bar, the queue and the <video> element, and actions
/// are clicks on the page's own buttons and keys on its volume slider — the
/// same things a person would do, so YouTube Music's own state stays right.
enum YTMusicBridge {
    static let chromeID = "com.google.Chrome"

    enum Failure: LocalizedError {
        case chromeNotRunning, noTab, javascriptDisabled, notAllowed, other(String)
        var errorDescription: String? {
            switch self {
            case .chromeNotRunning: return "YouTube Music（Chrome）が起動していません"
            case .noTab: return "YouTube Music のタブが見つかりません"
            case .javascriptDisabled:
                return "Chrome の［表示］>［開発 / 管理］>［Apple Events からの JavaScript を許可］をオンにしてください"
            case .notAllowed:
                return "MenuQueue が Chrome を操作する許可がありません（システム設定 > プライバシーとセキュリティ > オートメーション）"
            case .other(let m): return m
            }
        }
    }

    static var chromeRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: chromeID).isEmpty
    }

    /// The tab actions go to: the one last seen playing, or the best candidate.
    private static let targetLock = NSLock()
    private static var target: (window: Int, tab: Int)?

    // MARK: In-page scripts

    static let stateScript = #"""
    (() => {
      const bar = document.querySelector('ytmusic-player-bar');
      if (!bar) return JSON.stringify({ok: false});
      const v = document.querySelector('video');
      const t = (el) => el ? el.textContent.trim().replace(/\s+/g, ' ') : '';
      const label = (el) => el ? (el.getAttribute('title') || el.getAttribute('aria-label') || '') : '';
      const img = bar.querySelector('img.image') || bar.querySelector('img');
      const slider = bar.querySelector('#volume-slider');
      // Each queue entry has a hidden song/video counterpart; skip those.
      const items = [...document.querySelectorAll('ytmusic-player-queue-item')]
        .filter(i => !i.closest('#counterpart-renderer'));
      return JSON.stringify({
        ok: true,
        title: t(bar.querySelector('.title')),
        byline: t(bar.querySelector('.byline')),
        artwork: img ? img.src : '',
        playing: !!v && !v.paused,
        position: v ? v.currentTime : 0,
        duration: v && isFinite(v.duration) ? v.duration : 0,
        volume: slider ? Number(slider.getAttribute('aria-valuenow')) : 0,
        muted: !!v && v.muted,
        repeat: label(bar.querySelector('.repeat')),
        current: items.findIndex(i => i.hasAttribute('selected')),
        queue: items.map(i => ({
          title: t(i.querySelector('.song-title')),
          artist: t(i.querySelector('.byline')),
          duration: t(i.querySelector('.duration')),
          thumb: (i.querySelector('img') || {}).src || ''
        }))
      });
    })()
    """#

    enum Action {
        case playPause, next, previous, shuffle, cycleRepeat, toggleMute
        case seek(Double)
        case volume(Int)
        case jump(Int)

        var script: String {
            let click = { (selector: String) in
                "(() => { const b = document.querySelector('ytmusic-player-bar \(selector)'); if (!b) return 'missing'; b.click(); return 'ok'; })()"
            }
            switch self {
            case .playPause: return click("#play-pause-button")
            case .next: return click(".next-button")
            case .previous: return click(".previous-button")
            case .shuffle: return click(".shuffle")
            case .cycleRepeat: return click(".repeat")
            case .toggleMute: return click(".volume")
            case .seek(let seconds):
                return "(() => { const v = document.querySelector('video'); if (!v) return 'missing'; v.currentTime = \(max(seconds, 0)); return 'ok'; })()"
            case .volume(let target):
                // Step the page's own slider so YouTube Music records the new
                // level itself, instead of setting the media element's gain,
                // which it would put back on the next track.
                let goal = min(max(target, 0), 100)
                return """
                (() => {
                  const s = document.querySelector('ytmusic-player-bar #volume-slider');
                  if (!s) return 'missing';
                  const key = (k, c) => s.dispatchEvent(new KeyboardEvent('keydown', {key: k, code: k, keyCode: c, which: c, bubbles: true, composed: true}));
                  for (let i = 0; i < 101; i++) {
                    const now = Number(s.getAttribute('aria-valuenow'));
                    if (now === \(goal)) break;
                    if (now < \(goal)) key('ArrowUp', 38); else key('ArrowDown', 40);
                  }
                  return 'ok';
                })()
                """
            case .jump(let index):
                return """
                (() => {
                  const items = [...document.querySelectorAll('ytmusic-player-queue-item')]
                    .filter(i => !i.closest('#counterpart-renderer'));
                  const it = items[\(index)];
                  if (!it) return 'missing';
                  const b = it.querySelector('ytmusic-play-button-renderer') || it;
                  b.click();
                  return 'ok';
                })()
                """
            }
        }
    }

    // MARK: AppleScript

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func classify(_ error: Error) -> Failure {
        let text = error.localizedDescription
        if text.contains("JavaScript") && (text.contains("オフ") || text.contains("turned off")) { return .javascriptDisabled }
        if text.contains("-1743") || text.contains("許可されていません") || text.contains("not allowed") { return .notAllowed }
        return .other(text)
    }

    /// Reads every YouTube Music tab and picks the one to follow: playing
    /// beats paused-with-a-song beats empty. Remembers it for actions.
    static func readState() throws -> YTState {
        guard chromeRunning else { throw Failure.chromeNotRunning }
        let source = """
        set mqOut to ""
        tell application id "\(chromeID)"
            repeat with mqW in windows
                repeat with mqT in tabs of mqW
                    if URL of mqT contains "music.youtube.com" then
                        set mqR to execute mqT javascript \(appleScriptString(stateScript))
                        set mqOut to mqOut & (id of mqW) & (character id 31) & (id of mqT) & (character id 31) & mqR & (character id 30)
                    end if
                end repeat
            end repeat
        end tell
        return mqOut
        """
        let raw: String
        do { raw = try ScriptRunner.state.string(source) } catch { throw classify(error) }
        var best: (state: YTState, window: Int, tab: Int, score: Int)?
        for record in raw.components(separatedBy: "\u{1E}") where !record.isEmpty {
            let f = record.components(separatedBy: "\u{1F}")
            guard f.count >= 3, let w = Int(f[0]), let t = Int(f[1]), let s = YTPayload.parse(f[2]) else { continue }
            let score = s.playing ? 3 : s.hasTrack ? 2 : 1
            if best == nil || score > best!.score { best = (s, w, t, score) }
        }
        guard let best else { throw Failure.noTab }
        targetLock.lock(); target = (best.window, best.tab); targetLock.unlock()
        return best.state
    }

    static func perform(_ action: Action) throws {
        guard chromeRunning else { throw Failure.chromeNotRunning }
        targetLock.lock(); let t = target; targetLock.unlock()
        guard let t else { throw Failure.noTab }
        let source = """
        tell application id "\(chromeID)"
            return execute (tab id \(t.tab) of window id \(t.window)) javascript \(appleScriptString(action.script))
        end tell
        """
        let result: String
        do { result = try ScriptRunner.transport.string(source) } catch { throw classify(error) }
        if result.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
            throw Failure.other("YouTube Music の画面に操作ボタンが見つかりません")
        }
    }

    /// Opens the installed YouTube Music app if there is one, else the site.
    static func openYouTubeMusic() {
        let pwa = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Chrome Apps.localized/YouTube Music.app")
        if FileManager.default.fileExists(atPath: pwa.path) {
            NSWorkspace.shared.openApplication(at: pwa, configuration: .init())
        } else if let url = URL(string: "https://music.youtube.com") {
            NSWorkspace.shared.open(url)
        }
    }
}
