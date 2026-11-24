import Foundation

@main
struct MusicStatusPayloadTests {
    static func main() throws {
        func fields(id: Int = 1334, metadataID: Int = 1334, name: String = "キッズリターン!",
                    duration: String = "230,91", settings: [String]? = ["false", "all", "37", "false"],
                    state: String = "playing") -> [String] {
            [state, String(id), "12,3", String(metadataID), name, "ハンブレッダーズ", "Single", duration]
                + (settings ?? ["", "", "", ""])
        }
        func raw(_ columns: [String]) -> String { columns.joined(separator: "\u{1E}") }
        func payload(_ columns: [String]) throws -> MusicStatusPayload { try MusicStatusPayload(raw(columns)) }

        let cache = MusicStatusCache()
        var executions = 0
        let cold = try cache.read { request in
            executions += 1
            assert(request.cachedTrackID == 0 && request.settingsDue)
            return raw(fields(name: "  キッズ\nリターン! 🎵  "))
        }
        assert(executions == 1 && cold.track?.databaseID == 1334)
        assert(cold.track?.name == "  キッズ\nリターン! 🎵  " && cold.volume == 37 && cold.repeatMode == "all")
        assert(abs((cold.track?.duration ?? 0) - 230.91) < 0.001 && cold.position == 12.3)
        for _ in 0..<2 {
            let warm = try cache.read { request in
                executions += 1
                assert(request.cachedTrackID == 1334 && !request.settingsDue)
                return raw(fields(metadataID: 0, name: "", duration: "0", settings: nil))
            }
            assert(warm.track == cold.track && warm.volume == 37 && warm.repeatMode == "all")
        }
        _ = try cache.read { request in
            executions += 1
            assert(request.cachedTrackID == 1334 && request.settingsDue,
                   "settings must be fetched every third warm poll")
            return raw(fields(metadataID: 0, name: "", duration: "0"))
        }
        assert(executions == 4)
        print("PASS: cold and warm polls execute once; metadata is cached and settings refresh every third poll")

        let mismatchRequest = cache.beginRead()
        let mismatch = cache.finish(try payload(fields(id: 2872, metadataID: 1334)), for: mismatchRequest)
        assert(mismatch.track?.databaseID == 2872 && mismatch.track?.name == "" && mismatch.track?.duration == 0)
        let retry = cache.beginRead()
        assert(retry.cachedTrackID == 1334, "an ID mismatch must not cache another track's metadata")
        let empty = cache.finish(try payload(fields(id: 2872, metadataID: 2872, name: "", duration: "0")), for: retry)
        assert(empty.track?.name == "")
        assert(cache.beginRead().cachedTrackID == 1334, "empty metadata must be retried")
        let durationPending = cache.beginRead()
        _ = cache.finish(try payload(fields(id: 2872, metadataID: 2872, name: "あかねさす頃", duration: "0")),
                         for: durationPending)
        assert(cache.beginRead().cachedTrackID == 1334, "a missing duration must be retried while Music loads it")
        let ready = cache.beginRead()
        _ = cache.finish(try payload(fields(id: 2872, metadataID: 2872, name: "あかねさす頃", duration: "210.23")),
                         for: ready)
        assert(cache.beginRead().cachedTrackID == 2872)
        let stoppedRequest = cache.beginRead()
        let stopped = cache.finish(try payload(fields(id: 0, metadataID: 2872, state: "stopped")),
                                   for: stoppedRequest)
        assert(stopped.state == .stopped && stopped.track == nil && cache.beginRead().cachedTrackID == 0)
        print("PASS: changed IDs reject stale metadata; empty metadata retries; a zero ID clears the track")

        let generationCache = MusicStatusCache()
        let outdated = generationCache.beginRead()
        generationCache.invalidateSettings()
        _ = generationCache.finish(try payload(fields()), for: outdated)
        let afterWrite = generationCache.beginRead()
        assert(afterWrite.settingsDue && afterWrite.settings == nil,
               "a pre-write settings read must not refill an invalidated cache")
        _ = generationCache.finish(try payload(fields(settings: ["true", "one", "62", "false"])), for: afterWrite)
        _ = generationCache.finish(try payload(fields(settings: ["false", "off", "1", "true"])), for: outdated)
        let fresh = generationCache.beginRead()
        assert(fresh.settings?.volume == 62 && fresh.settings?.repeatMode == "one" && fresh.settings?.shuffle == true)
        print("PASS: an invalidated or out-of-order settings result cannot overwrite a newer cache")

        let orderedCache = MusicStatusCache()
        let earlier = orderedCache.beginRead()
        let later = orderedCache.beginRead()
        _ = orderedCache.finish(try payload(fields(id: 2872, metadataID: 2872, name: "あかねさす頃")), for: later)
        _ = orderedCache.finish(try payload(fields()), for: earlier)
        assert(orderedCache.beginRead().cachedTrackID == 2872,
               "an out-of-order poll must not move the metadata cache back to an older track")

        let childCache = MusicStatusCache()
        var children = 0
        let runner = ScriptRunner(label: "status-test", deadline: 3, makeProcess: {
            children += 1
            return Process()
        })
        func runPayload(_ columns: [String]) throws -> String {
            let quoted = columns.map {
                "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }.joined(separator: ", ")
            return try runner.string("""
                set AppleScript's text item delimiters to (character id 30)
                return {\(quoted)} as text
                """)
        }
        let childResult = try childCache.read { _ in
            try runPayload(fields())
        }
        assert(children == 1 && childResult.track?.databaseID == 1334 && childResult.volume == 37,
               "a cold read with metadata and settings must launch exactly one real child")
        let warmChildResult = try childCache.read { request in
            assert(request.cachedTrackID == 1334 && !request.settingsDue)
            return try runPayload(fields(metadataID: 0, name: "", duration: "0", settings: nil))
        }
        assert(children == 2 && warmChildResult.track == childResult.track && warmChildResult.volume == 37,
               "a warm response's trailing empty columns must survive real child output")
        print("PASS: a cold status read launches exactly one real osascript child; no Music commands are sent")

        do {
            _ = try MusicStatusPayload("playing\u{1E}1334")
            assertionFailure("a malformed response must report a read error rather than look stopped")
        } catch is MusicStatusPayload.InvalidPayload {}
        print("PASS: malformed status output reports a read failure")
    }
}
