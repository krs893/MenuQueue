import SwiftUI
import Combine
import AppKit
import ServiceManagement

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct ContentView: View {
    @ObservedObject var player: PlayerController
    @ObservedObject var store: QueueStore
    @StateObject private var library = LibraryModel()
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingHeader(player: player, showSettings: $showSettings)
            Divider()
            TransportBar(player: player)
                .padding(.vertical, 4)
            Divider()

            if showSettings {
                SettingsPanel(player: player, store: store, close: { showSettings = false })
            } else {
                // Reading Music's queue needs Accessibility and adding to it is
                // not possible on this macOS at all, so the panel is now just
                // what is playing, the controls, and a way to start something.
                LibraryTab(library: library, player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 8)
            }

            if let err = player.lastError {
                // Spelled out rather than hidden in a tooltip: an orange
                // triangle alone gives no way to tell a missing permission
                // from a track that could not be found.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
                .accessibilityLabel(err)
            }
        }
        // Below the panel's own height, so the panel sets the size rather than
        // the content pushing it taller.
        .frame(minWidth: 340, minHeight: 300, maxHeight: .infinity)
        .onAppear {
            library.loadPlaylists()
        }
    }
}

// MARK: - Now playing

struct NowPlayingHeader: View {
    @ObservedObject var player: PlayerController
    @Binding var showSettings: Bool
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                artworkView
                VStack(alignment: .leading, spacing: 2) {
                    if !player.musicRunning {
                        Button { player.launchMusic() } label: {
                            Image(systemName: "music.note.house.fill").font(.title2)
                        }.buttonStyle(.borderless).help("ミュージックを開く")
                    } else if let t = player.now.track {
                        Text(t.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                        Text(t.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary).help("再生していません")
                    }
                    if player.owns {
                        Image(systemName: "waveform")
                            .font(.system(size: 11)).help("キュー再生中")
                            .foregroundStyle(.tint)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: showSettings ? "xmark.circle" : "gearshape").frame(width: 32, height: 32)
                }
                .help(showSettings ? "設定を閉じる" : "設定")
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            progressView
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var artworkView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let art = player.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var progressView: some View {
        let duration = max(player.now.track?.duration ?? 0, 0.01)
        let value = scrubbing ? scrubValue : min(player.now.position, duration)
        VStack(spacing: 1) {
            Slider(value: Binding(
                get: { value },
                set: { scrubValue = $0 }
            ), in: 0...duration, onEditingChanged: { editing in
                scrubbing = editing
                if !editing { player.seek(to: scrubValue) }
            })
            .controlSize(.mini)
            .disabled(player.now.track == nil)

            HStack {
                Text(timeString(value)).font(.system(size: 11, design: .monospaced))
                Spacer()
                Text("-" + timeString(max(duration - value, 0))).font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct TransportBar: View {
    @ObservedObject var player: PlayerController

    private var muteSymbol: String {
        if player.isMuted { return "speaker.slash.fill" }
        switch player.now.volume {
        case 0: return "speaker.fill"
        case 1..<34: return "speaker.wave.1.fill"
        case 34..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 18) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.shuffleIsOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .overlay(alignment: .bottomTrailing) {
                        if player.isShuffleChanging {
                            Circle().fill(Color.accentColor).frame(width: 4, height: 4).offset(x: 5, y: 4)
                        }
                    }
            }
            .help(player.shuffleTargetsQueue
                  ? "キューをシャッフル（並びはキュータブに反映されます）"
                  : "Music.app のシャッフル")

            Button { player.previous() } label: { Image(systemName: "backward.fill").frame(width: 28, height: 32) }.help("前の曲 / 曲の先頭")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.now.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(player.canStartPlayback ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
            .disabled(!player.canStartPlayback)
            .help(player.playbackUnavailableReason ?? (player.now.state.isPlaying ? "一時停止" : "再生"))
            Button { player.next() } label: {
                ZStack {
                    Image(systemName: "forward.fill").opacity(player.pendingSkipCount > 0 ? 0.35 : 1)
                    if player.pendingSkipCount > 0 { ProgressView().controlSize(.mini) }
                }.frame(width: 32, height: 36)
            }.help("次の曲").accessibilityLabel("次の曲")

            Button { player.cycleRepeat() } label: {
                Image(systemName: player.displayedRepeat == "one" ? "repeat.1" : "repeat")
                    .foregroundStyle(player.displayedRepeat == "off" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .help("リピート: " + (player.displayedRepeat == "off" ? "オフ" : player.displayedRepeat == "all" ? "すべて" : "1曲"))

            Spacer(minLength: 4)

            Button { player.toggleMute() } label: {
                Image(systemName: muteSymbol)
                    .font(.system(size: 11))
                    .frame(width: 18)
                    .foregroundStyle(player.isMuted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .help(player.isMuted ? "ミュート解除" : "ミュート")
            .accessibilityLabel(player.isMuted ? "ミュート解除" : "ミュート")

            Slider(value: Binding(
                get: { Double(player.now.volume) },
                set: { player.setVolume(Int($0)) }
            ), in: 0...100)
            .controlSize(.mini)
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Current Music queue

struct LibraryTab: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var player: PlayerController
    @StateObject private var artwork = ArtworkStore()
    private let controlSize: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if library.canGoBack {
                    Button { library.goBack() } label: {
                        Image(systemName: "chevron.left").frame(width: controlSize, height: controlSize)
                    }.help("戻る")
                }
                if let title = library.selectedPlaylist?.name ?? library.currentFolder?.name {
                    Text(title).font(.subheadline).bold().lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
                }
                if let selected = library.selectedPlaylist {
                    // "Add to queue" is gone: it drove Music's toolbar menu
                    // through Accessibility, and on macOS 26 that toolbar
                    // exposes no children at all, so it never added anything.
                    Button {
                        Task { await player.playNativePlaylist(selected.id) }
                    } label: { Image(systemName: "play.fill").frame(width: controlSize, height: controlSize) }
                    .help("プレイリストを再生").accessibilityLabel("プレイリストを再生")
                    .disabled(library.playlistTracks.isEmpty)
                }
                Spacer(minLength: 0)
                Button {
                    library.reloadEverything()
                } label: {
                    Group {
                        if library.isLoadingPlaylists || library.isLoadingTracks { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }.frame(width: controlSize, height: controlSize)
                }
                .help("ライブラリを読み直す")
                .accessibilityLabel("ライブラリを読み直す")
                .disabled(library.isLoadingPlaylists || library.isLoadingTracks)
                if let entry = library.selectedPlaylist ?? library.currentFolder {
                    shuffleButton(for: entry)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if let error = library.playlistError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.system(size: 11))
                    Text(error)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .accessibilityLabel(error)
            }
            playlistSection
        }
    }

    private func shuffleButton(for entry: PlaylistInfo) -> some View {
        Button {
            Task { await library.shufflePlay(entry, player: player) }
        } label: {
            Group {
                if library.isPreparingShuffle {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "shuffle")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: controlSize, height: controlSize)
            .contentShape(Circle())
        }
        .buttonStyle(ShufflePlayButtonStyle())
        .disabled(library.isPreparingShuffle)
        .help(entry.isFolder ? "子フォルダを含む全曲をシャッフル再生" : "プレイリストをシャッフル再生")
        .accessibilityLabel("\(entry.name)をシャッフル再生")
    }

    @ViewBuilder private var playlistSection: some View {
        if library.selectedPlaylist != nil {
            if library.playlistTracks.isEmpty {
                EmptyHint(icon: library.isLoadingTracks ? "hourglass" : "music.note.list",
                          text: library.isLoadingTracks ? "読み込み中…" : "このプレイリストは空です")
            } else {
                // Indexed rather than keyed by track: the row's position is what
                // says where in the playlist to start, and a playlist can hold
                // the same song twice.
                List(Array(library.playlistTracks.enumerated()), id: \.offset) { index, track in
                    TrackPickRow(track: track,
                                 isPlaying: player.now.track?.databaseID == track.databaseID
                                    && player.now.state.isPlaying,
                                 play: {
                                     let tracks = library.playlistTracks
                                     Task { await player.playFromPlaylist(tracks, startAt: index) }
                                 },
                                 artwork: artwork)
                }
                .listStyle(.plain)
            }
        } else if library.visibleEntries.isEmpty {
            EmptyHint(icon: "music.note.list",
                      text: library.isLoadingPlaylists ? "読み込み中…"
                          : library.currentFolder == nil ? "プレイリストが見つかりません"
                          : "このフォルダは空です")
        } else {
            List(library.visibleEntries) { entry in
                HStack {
                    Image(systemName: entry.isFolder ? "folder" : "music.note.list")
                        .foregroundStyle(.secondary).font(.system(size: 11))
                        .frame(width: 16)
                    Text(entry.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text("\(entry.isFolder ? library.childCount(of: entry) : entry.count)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    if entry.isFolder {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if entry.isFolder { library.enter(entry) } else { library.loadTracks(of: entry) }
                }
                .help(entry.isFolder ? "フォルダを開く" : "プレイリストを開く")
            }
            .listStyle(.plain)
        }
    }
}

private struct ShufflePlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.9 : 0.35))
            .background {
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : isHovered ? 0.11 : 0.06))
            }
            .overlay {
                Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// A square of album art, or a placeholder of the same size so rows do not
/// shift as pictures arrive.
struct ArtworkThumbnail: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: ArtworkStore.side, height: ArtworkStore.side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Whether the media keys are being handled, and a way to grant the
/// permission they need. Rechecked every couple of seconds, since the grant
/// happens in System Settings rather than here.
struct MediaKeyStatusRow: View {
    @State private var trusted = MediaKeyTap.isTrusted
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "playpause")
                .frame(width: 28)
                .foregroundStyle(trusted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text("メディアキー").font(.system(size: 12))
                Text(trusted ? "キュー再生中は次へ・前へをキューで処理します"
                             : "アクセシビリティの許可が必要です")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !trusted {
                Button("許可") { MediaKeyTap.requestTrust() }.controlSize(.small)
            }
        }
        .onReceive(tick) { _ in trusted = MediaKeyTap.isTrusted }
    }
}

struct TrackPickRow: View {
    let track: MusicTrack
    var isPlaying: Bool = false
    let play: () -> Void
    @ObservedObject var artwork: ArtworkStore

    var body: some View {
        Button(action: play) {
            HStack(spacing: 10) {
                ArtworkThumbnail(image: artwork.thumbnail(for: track))
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name).font(.system(size: 14)).lineLimit(1)
                    Text(track.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.fill")
                    .foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 32, height: 32)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Rows fetch their own art as they scroll into view, so a long
        // playlist only pays for what is on screen.
        .task(id: ArtworkStore.key(track)) { await artwork.load(track) }
        .help("再生").accessibilityLabel("\(track.name)を再生")
    }

}

// MARK: - Bits

struct EmptyHint: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.tertiary).help(text)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsPanel: View {
    @ObservedObject var player: PlayerController
    @ObservedObject var store: QueueStore
    let close: () -> Void

    @State private var loginItemOn = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "power").frame(width: 28).help("ログイン時に起動")
                    Spacer()
                    Toggle("ログイン時に起動", isOn: $loginItemOn).labelsHidden()
                        .onChange(of: loginItemOn) { _, newValue in
                            loginItemError = LoginItem.set(newValue)
                            loginItemOn = LoginItem.isEnabled
                        }
                }
                if let error = loginItemError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(error)
                }
                Divider()
                MediaKeyStatusRow()
                Divider()
                HStack {
                    Button(action: close) { Image(systemName: "chevron.left") }.help("戻る")
                    Spacer()
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "rectangle.portrait.and.arrow.right") }
                        .help("MenuQueueを終了")
                }

            }
            .padding(14)
        }
    }
}
