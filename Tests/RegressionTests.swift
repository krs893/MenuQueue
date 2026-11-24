import Foundation
import AppKit

@main
struct RegressionTests {
    /// Syntax-checks JavaScript with the system's JavaScript compiler. The DOM
    /// is not there, but a typo in a script sent to the page is caught here
    /// instead of silently doing nothing in YouTube Music.
    static func compiles(_ js: String) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mq-\(UUID().uuidString).js")
        defer { try? FileManager.default.removeItem(at: url) }
        try? js.write(to: url, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        p.arguments = ["-l", "JavaScript", "-o", "/dev/null", url.path]
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @MainActor static func main() async throws {
        // --- Reading the page -------------------------------------------------
        let byline = YTPayload.splitByline("muque • Just As You Are • 2026")
        assert(byline.artist == "muque" && byline.album == "Just As You Are")
        let video = YTPayload.splitByline("ZUTOMAYO • 12M views • 2.1M likes")
        assert(video.artist == "ZUTOMAYO" && video.album == "", "a video's view count is not an album")
        assert(YTPayload.splitByline("") == ("", ""))

        let small = "https://yt3.googleusercontent.com/abc=w60-h60-l90-rj"
        assert(YTPayload.enlarge(small, to: 544)?.absoluteString == "https://yt3.googleusercontent.com/abc=w544-h544-l90-rj")
        assert(YTPayload.enlarge("data:image/gif;base64,R0lGOD", to: 120) == nil, "placeholders are not artwork")

        let payload = """
        {"ok":true,"title":"いいんじゃない - Just As You Are","byline":"muque • Just As You Are • 2026",
         "artwork":"\(small)","playing":true,"position":30.4,"duration":177,"volume":40,"muted":false,
         "repeat":"Repeat all","current":1,
         "queue":[{"title":"a","artist":"x","duration":"2:57","thumb":"data:image/gif;base64,AA"},
                  {"title":"b","artist":"y","duration":"3:16","thumb":"\(small)"}]}
        """
        let s = YTPayload.parse(payload)!
        assert(s.title == "いいんじゃない - Just As You Are" && s.artist == "muque" && s.album == "Just As You Are")
        assert(s.playing && s.duration == 177 && s.volume == 40 && s.repeatMode == "all")
        assert(s.queue.count == 2 && s.currentIndex == 1 && s.queue[0].thumbnail == nil && s.queue[1].thumbnail != nil)
        assert(YTPayload.parse(#"{"ok":false}"#) == nil, "a page without a player is not a state")
        assert(YTPayload.parse("garbage") == nil)
        let odd = YTPayload.parse(#"{"ok":true,"title":"t","duration":null,"position":-3,"current":9,"queue":[],"repeat":"Repeat one"}"#)!
        assert(odd.duration == 0 && odd.position == 0 && odd.currentIndex == nil && odd.repeatMode == "one",
               "missing, negative and out-of-range values must not reach the UI")
        print("PASS: the YouTube Music page state parses, including videos, placeholders and odd values")

        // --- Scripts sent to the page ----------------------------------------
        assert(compiles(YTMusicBridge.stateScript), "state script has a syntax error")
        let actions: [YTMusicBridge.Action] = [.playPause, .next, .previous, .shuffle, .cycleRepeat,
                                               .toggleMute, .seek(12.5), .volume(55), .volume(-9), .jump(3)]
        for a in actions { assert(compiles(a.script), "action script has a syntax error: \(a)") }
        assert(YTMusicBridge.Action.volume(250).script.contains("=== 100"), "volume is clamped to the slider's range")
        print("PASS: every script sent to the page compiles")

        // --- Menu bar ticker --------------------------------------------------
        assert(!Marquee.scrolls("短い", width: 14))
        let long = "とても長い曲名がここにあって収まらない"
        for step in 0..<200 { assert(Marquee.window(long, width: 8, step: step).count == 8) }
        let period = long.count + Marquee.gap.count
        assert(Marquee.window(long, width: 8, step: period) == Marquee.window(long, width: 8, step: 0))
        assert(Marquee.parked(long, width: 8) == String(long.prefix(7)) + "…")
        let tickerView = TickerView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        tickerView.show("MMMMMMMMMMMMMMMM", font: NSFont.systemFont(ofSize: 12))
        let tickerBitmap = NSBitmapImageRep(cgImage: tickerView.layer!.sublayers!.first!.contents as! CGImage)
        var lastInkX = 0
        for x in 0..<tickerBitmap.pixelsWide {
            for y in 0..<tickerBitmap.pixelsHigh where (tickerBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                lastInkX = x; break
            }
        }
        assert(Double(lastInkX) > Double(tickerBitmap.pixelsWide) * 0.9, "title must be drawn at its real size")
        tickerView.stop()
        print("PASS: the menu bar ticker keeps its width, loops and draws at display scale")

        // --- Discord ----------------------------------------------------------
        var wire = DiscordIPC.encode(opcode: DiscordIPC.frame, json: ["cmd": "SET_ACTIVITY"])!
        var partial = wire.prefix(wire.count - 1)
        assert(DiscordIPC.decode(&partial) == nil)
        let frame = DiscordIPC.decode(&wire)
        assert(frame?.opcode == 1 && (frame?.json["cmd"] as? String) == "SET_ACTIVITY" && wire.isEmpty)
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let song = PresenceTrack(id: "1", name: "ハイキ", artist: "リーガルリリー", album: "kirin",
                                 duration: 216, artworkURL: "https://x/a=w544-h544")
        let act = DiscordActivity.make(track: song, position: 16, artworkURL: song.artworkURL, now: clock)
        assert(act["type"] as? Int == 2 && act["details"] as? String == "ハイキ" && act["state"] as? String == "リーガルリリー")
        assert(act["status_display_type"] as? Int == 2, "the status line names the song")
        let ts = act["timestamps"] as! [String: Int64]
        assert(ts["start"] == 999_984_000 && ts["end"] == 1_000_200_000)
        assert((act["assets"] as! [String: Any])["large_image"] as? String == "https://x/a=w544-h544")
        assert(DiscordActivity.fit("A").count == 2 && DiscordActivity.fit(String(repeating: "あ", count: 300)).count == 128)
        assert(DiscordPresence.defaultClientID == "1177081335727267940", "shows as YouTube Music")
        print("PASS: Discord frames and the listening activity follow Discord's rules")

        // --- Panel placement ----------------------------------------------------
        let displays: [CGRect] = [
            CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 1440, y: -300, width: 1920, height: 1080), CGRect(x: 0, y: 900, width: 1280, height: 720),
            CGRect(x: 0, y: -600, width: 1024, height: 600)
        ]
        for screen in displays {
            let visible = CGRect(x: screen.minX, y: screen.minY + 40, width: screen.width, height: screen.height - 65)
            for x in [screen.minX + 2, screen.midX, screen.maxX - 2] {
                let f = PanelPlacement.frame(click: CGPoint(x: x, y: screen.maxY - 12),
                                             button: CGRect(x: 6000, y: 8000, width: 200, height: 24),
                                             screen: screen, visible: visible)
                assert(visible.contains(f))
            }
        }
        print("PASS: panel placement stays on the clicked display")
    }
}
