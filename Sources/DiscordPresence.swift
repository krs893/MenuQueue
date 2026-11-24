import Foundation

/// Discord's local RPC frames: little-endian opcode and length, then JSON.
enum DiscordIPC {
    static let handshake: UInt32 = 0
    static let frame: UInt32 = 1
    static let close: UInt32 = 2

    static func encode(opcode: UInt32, json: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        var data = Data()
        withUnsafeBytes(of: opcode.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }

    /// Splits one frame off the front of `buffer`, if a whole one has arrived.
    static func decode(_ buffer: inout Data) -> (opcode: UInt32, json: [String: Any])? {
        guard buffer.count >= 8 else { return nil }
        let header = [UInt8](buffer.prefix(8))
        let op = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        let len = Int(UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24)
        guard buffer.count >= 8 + len else { return nil }
        let body = buffer.subdata(in: buffer.startIndex + 8 ..< buffer.startIndex + 8 + len)
        buffer.removeFirst(8 + len)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return (op, json)
    }
}

/// The track as Discord needs it, whichever player it came from.
struct PresenceTrack: Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var duration: Double
    /// A cover image URL when the player already has one.
    var artworkURL: String?
}

/// What Discord shows for a track: "Listening to …", with the song, the
/// artist, a progress bar and the cover. Pure, so it is tested directly.
enum DiscordActivity {
    /// Discord rejects strings shorter than 2 or longer than 128 characters.
    static func fit(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 128 { t = String(t.prefix(127)) + "…" }
        while t.count < 2 { t += " " }
        return t
    }

    static func make(track: PresenceTrack, position: Double, artworkURL: String?, now: Date) -> [String: Any] {
        let start = now.addingTimeInterval(-max(position, 0))
        var activity: [String: Any] = [
            "type": 2,                       // Listening
            "details": fit(track.name),
            // What the member list and the status line say after "Listening to":
            // 0 the app's name, 1 the state (artist), 2 the details (the song).
            "status_display_type": 2,
        ]
        if !track.artist.isEmpty { activity["state"] = fit(track.artist) }
        if track.duration > 0 {
            activity["timestamps"] = [
                "start": Int64(start.timeIntervalSince1970 * 1000),
                "end": Int64(start.addingTimeInterval(track.duration).timeIntervalSince1970 * 1000),
            ]
        }
        var assets: [String: Any] = [:]
        if let artworkURL { assets["large_image"] = artworkURL }
        if !track.album.isEmpty { assets["large_text"] = fit(track.album) }
        if !assets.isEmpty { activity["assets"] = assets }
        return activity
    }
}

/// Shows the track playing in Music as a Discord activity while it plays,
/// and clears it on pause or stop.
///
/// Talks to the Discord app over its local socket, on a queue of its own:
/// a Discord that is closed, restarting or slow never holds up the menu bar.
/// Updates go out only when something changes — another track, play/pause,
/// or a seek — since Discord limits how often an activity may be set.
final class DiscordPresence {
    static let shared = DiscordPresence()

    static let enabledKey = "discordPresenceEnabled"
    static let clientIDKey = "discordClientID"
    /// The public "YouTube Music" application of pear-devs/pear-desktop, so
    /// the activity reads "Listening to YouTube Music". It belongs to that
    /// project; replace it with one's own with
    /// `defaults write jp.local.menuqueue discordClientID <id>`.
    static let defaultClientID = "1177081335727267940"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private let queue = DispatchQueue(label: "jp.menuqueue.discord", qos: .utility)
    private var fd: Int32 = -1
    private var buffer = Data()
    private var sentKey: String?
    private var sentStart: Date?
    private var artwork: [String: String] = [:]   // album key → URL ("" = none found)

    private var clientID: String {
        UserDefaults.standard.string(forKey: Self.clientIDKey) ?? Self.defaultClientID
    }

    /// The track playing now, or nil when nothing is (paused, stopped, gone).
    func update(_ track: PresenceTrack?, position: Double) {
        let enabled = Self.isEnabled
        let now = Date()
        queue.async { self.apply(track, position: position, enabled: enabled, now: now) }
    }

    func shutdown() {
        queue.sync {
            if fd >= 0 { _ = send(op: DiscordIPC.frame, clearPayload()); Darwin.close(fd); fd = -1 }
        }
    }

    // MARK: - On the queue

    private func apply(_ track: PresenceTrack?, position: Double, enabled: Bool, now: Date) {
        guard enabled, let track, !track.name.isEmpty else {
            if sentKey != nil, fd >= 0 { _ = send(op: DiscordIPC.frame, clearPayload()) }
            sentKey = nil
            sentStart = nil
            return
        }
        let key = "\(track.id)|\(track.name)"
        let start = now.addingTimeInterval(-position)
        // Same song still playing where it should be: nothing to tell Discord.
        if key == sentKey, let sentStart, abs(sentStart.timeIntervalSince(start)) < 3 { return }

        guard connect() else { return }
        let url = track.artworkURL ?? artworkURL(for: track)
        let activity = DiscordActivity.make(track: track, position: position, artworkURL: url, now: now)
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": ["pid": Int(ProcessInfo.processInfo.processIdentifier), "activity": activity],
            "nonce": UUID().uuidString,
        ]
        if send(op: DiscordIPC.frame, payload) {
            sentKey = key
            sentStart = start
            EventLog.shared.note("discord  \(track.name) / \(track.artist)\(url == nil ? "  (no artwork)" : "")")
        }
    }

    private func clearPayload() -> [String: Any] {
        ["cmd": "SET_ACTIVITY",
         "args": ["pid": Int(ProcessInfo.processInfo.processIdentifier)],
         "nonce": UUID().uuidString]
    }

    /// Connects and handshakes if not already connected. Discord may not be
    /// running; that is not an error, it just means nothing to show.
    private func connect() -> Bool {
        if fd >= 0 { return true }
        let dir = NSTemporaryDirectory()
        for n in 0..<10 {
            let path = (dir as NSString).appendingPathComponent("discord-ipc-\(n)")
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(s); continue }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
            }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            guard ok else { Darwin.close(s); continue }
            fd = s
            buffer.removeAll()
            guard send(op: DiscordIPC.handshake, ["v": 1, "client_id": clientID]),
                  let ready = readFrame(), (ready.json["evt"] as? String) == "READY"
            else {
                EventLog.shared.note("discord  handshake failed on \(path)")
                disconnect()
                continue
            }
            EventLog.shared.note("discord  connected (\(path))")
            return true
        }
        return false
    }

    private func disconnect() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        sentKey = nil
        sentStart = nil
    }

    @discardableResult
    private func send(op: UInt32, _ json: [String: Any]) -> Bool {
        guard fd >= 0, let data = DiscordIPC.encode(opcode: op, json: json) else { return false }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { disconnect(); return false }
        // Discord answers every command; read it so the socket never backs up.
        if op == DiscordIPC.frame, let reply = readFrame(),
           let error = (reply.json["data"] as? [String: Any])?["message"] as? String,
           (reply.json["evt"] as? String) == "ERROR" {
            EventLog.shared.note("discord  error: \(error)")
        }
        return true
    }

    private func readFrame() -> (opcode: UInt32, json: [String: Any])? {
        var chunk = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<8 {
            if let frame = DiscordIPC.decode(&buffer) {
                if frame.opcode == DiscordIPC.close { disconnect(); return nil }
                return frame
            }
            let n = Darwin.read(fd, &chunk, chunk.count)
            guard n > 0 else { disconnect(); return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return nil
    }

    /// Cover art from Apple's public search API, the way most Apple Music
    /// presence tools do it: Music only hands out raw image bytes, and Discord
    /// needs a URL. Cached per album; a miss is cached too.
    private func artworkURL(for track: PresenceTrack) -> String? {
        let key = "\(track.artist.lowercased())|\(track.album.lowercased())"
        if let cached = artwork[key] { return cached.isEmpty ? nil : cached }
        var found = ""
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: "\(track.name) \(track.artist) \(track.album)"),
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "song"),
            .init(name: "country", value: "JP"),
            .init(name: "limit", value: "5"),
        ]
        if let url = components.url {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            let done = DispatchSemaphore(value: 0)
            var body: Data?
            URLSession.shared.dataTask(with: request) { data, _, _ in body = data; done.signal() }.resume()
            _ = done.wait(timeout: .now() + 5)
            if let body,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let results = json["results"] as? [[String: Any]] {
                let pick = results.first {
                    ($0["trackName"] as? String)?.localizedCaseInsensitiveCompare(track.name) == .orderedSame
                } ?? results.first
                if let art = pick?["artworkUrl100"] as? String {
                    found = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                }
            }
        }
        artwork[key] = found
        return found.isEmpty ? nil : found
    }
}
