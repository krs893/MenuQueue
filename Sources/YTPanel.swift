import SwiftUI
import AppKit

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct YTPanel: View {
    @ObservedObject var player: YTPlayer
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingHeader(player: player, showSettings: $showSettings)
            Divider()
            TransportBar(player: player)
            Divider()
            if let error = player.lastError {
                ErrorLine(text: error)
                Divider()
            }
            if showSettings {
                SettingsPanel(close: { showSettings = false })
            } else if !player.available {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.house").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("YouTube Music を開くと、ここに再生中の曲とキューが出ます")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("YouTube Music を開く") { YTMusicBridge.openYouTubeMusic() }
                        .controlSize(.small)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QueueList(player: player)
            }
        }
        .frame(minWidth: 340, minHeight: 300, maxHeight: .infinity)
        .onAppear { Task { await player.refresh() } }
    }
}

private struct Artwork: View {
    let url: URL?
    let side: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.clear }
            } else {
                Image(systemName: "music.note").foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct NowPlayingHeader: View {
    @ObservedObject var player: YTPlayer
    @Binding var showSettings: Bool
    @State private var scrubbing: Double?

    var body: some View {
        let s = player.state
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Artwork(url: s.artwork, side: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.hasTrack ? s.title : "再生していません")
                        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text([s.artist, s.album].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { showSettings.toggle() } label: {
                    Image(systemName: showSettings ? "xmark.circle" : "gearshape").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("設定")
            }
            let duration = max(s.duration, 1)
            VStack(spacing: 0) {
                Slider(value: Binding(get: { min(scrubbing ?? s.position, duration) },
                                      set: { scrubbing = $0 }),
                       in: 0...duration,
                       onEditingChanged: { editing in
                           if !editing, let target = scrubbing { player.seek(to: target); scrubbing = nil }
                       })
                .controlSize(.mini)
                .disabled(!s.hasTrack)
                HStack {
                    Text(timeString(scrubbing ?? s.position))
                    Spacer()
                    Text(timeString(s.duration))
                }
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }
}

private struct TransportBar: View {
    @ObservedObject var player: YTPlayer
    @State private var draggingVolume: Double?

    var body: some View {
        let s = player.state
        HStack(spacing: 14) {
            Button { player.shuffle() } label: { Image(systemName: "shuffle") }
                .help("キューをシャッフル")
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .help("前の曲")
            Button { player.togglePlayPause() } label: {
                Image(systemName: s.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
            }
            .help(s.playing ? "一時停止" : "再生")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .help("次の曲")
            Button { player.cycleRepeat() } label: {
                Image(systemName: s.repeatMode == "one" ? "repeat.1" : "repeat")
                    .foregroundStyle(s.repeatMode == "off" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .help("リピート: " + (s.repeatMode == "off" ? "オフ" : s.repeatMode == "all" ? "すべて" : "1曲"))
            Spacer(minLength: 4)
            Button { player.toggleMute() } label: {
                Image(systemName: s.muted || s.volume == 0 ? "speaker.slash.fill"
                      : s.volume < 34 ? "speaker.wave.1.fill" : s.volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                    .frame(width: 18)
                    .foregroundStyle(s.muted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .help(s.muted ? "ミュート解除" : "ミュート")
            // Sent once on release: each step is a key press on the page's
            // own slider, and a drag would send dozens.
            Slider(value: Binding(get: { draggingVolume ?? Double(s.volume) },
                                  set: { draggingVolume = $0 }),
                   in: 0...100,
                   onEditingChanged: { editing in
                       if !editing, let v = draggingVolume { player.setVolume(Int(v.rounded())); draggingVolume = nil }
                   })
            .controlSize(.mini).frame(width: 64)
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .disabled(!player.available)
    }
}

private struct QueueList: View {
    @ObservedObject var player: YTPlayer

    var body: some View {
        let s = player.state
        if s.queue.isEmpty {
            Text("キューは空です").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(s.queue) { item in
                    let current = item.index == s.currentIndex
                    Button { player.jump(to: item.index) } label: {
                        HStack(spacing: 10) {
                            Artwork(url: item.thumbnail, side: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 13, weight: current ? .semibold : .regular)).lineLimit(1)
                                Text(item.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if current {
                                Image(systemName: s.playing ? "speaker.wave.2.fill" : "pause.fill")
                                    .foregroundStyle(.tint).font(.system(size: 11))
                            } else {
                                Text(item.duration).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(item.index)
                    .help("この曲を再生")
                }
                .listStyle(.plain)
                .onAppear { if let c = s.currentIndex { proxy.scrollTo(c, anchor: .top) } }
                .onChange(of: s.currentIndex) { _, c in
                    if let c { withAnimation { proxy.scrollTo(c, anchor: .top) } }
                }
            }
        }
    }
}

private struct ErrorLine: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 11))
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

private struct SettingsPanel: View {
    let close: () -> Void
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var discord = DiscordPresence.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("ログイン時に起動", isOn: $loginItem)
                .onChange(of: loginItem) { _, on in
                    loginError = LoginItem.set(on)
                    loginItem = LoginItem.isEnabled
                }
            if let loginError { Text(loginError).font(.system(size: 10)).foregroundStyle(.red) }
            Toggle("Discord に再生中の曲を表示", isOn: $discord)
                .onChange(of: discord) { _, on in
                    DiscordPresence.isEnabled = on
                    if !on { DiscordPresence.shared.update(nil, position: 0) }
                }
            Divider()
            HStack {
                Button("YouTube Music を開く") { YTMusicBridge.openYouTubeMusic() }
                Spacer()
                Button("MenuQueue を終了") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
