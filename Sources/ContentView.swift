import SwiftUI
import AppKit
import ServiceManagement

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

enum Tab: String, CaseIterable, Identifiable {
    case queue = "キュー"
    case search = "検索"
    case playlists = "プレイリスト"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .queue: return "list.bullet"
        case .search: return "magnifyingglass"
        case .playlists: return "music.note.list"
        }
    }
}

struct ContentView: View {
    @ObservedObject var player: PlayerController
    @ObservedObject var store: QueueStore
    @StateObject private var library = LibraryModel()
    @StateObject private var upNext = UpNextModel()
    @State private var tab: Tab = .queue
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
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Image(systemName: $0.icon).help($0.rawValue).accessibilityLabel($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Group {
                    switch tab {
                    case .queue: UpNextTab(model: upNext)
                        .task(id: player.now.track?.databaseID) { upNext.refresh(openIfNeeded: true) }
                    case .search: LibraryTab(library: library, player: player, mode: .search)
                    case .playlists: LibraryTab(library: library, player: player, mode: .playlists)

                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let err = player.lastError {
                HStack {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).help(err).accessibilityLabel(err)
                }.padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
        .frame(minWidth: 360, minHeight: 480, maxHeight: .infinity)
        .onAppear {
            library.loadPlaylists()
        }
        .onChange(of: tab) { _, newValue in
            if newValue == .playlists { library.loadPlaylists() }
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
            }
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

            Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { Double(player.now.volume) },
                set: { player.setVolume(Int($0)) }
            ), in: 0...100)
            .controlSize(.mini)
            .frame(width: 70)
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Current Music queue

struct UpNextTab: View {
    @ObservedObject var model: UpNextModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "eye").foregroundStyle(.secondary).help("Music側のキュー・読み取り専用")
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { model.refresh(openIfNeeded: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.loading)
            }
            .padding(.horizontal, 10).padding(.bottom, 6)

            if let err = model.error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.secondary).help(err)
                    if !UpNextReader.isTrusted {
                        Button { UpNextReader.requestTrust() } label: {
                            Image(systemName: "lock.open").font(.title2)
                        }.help("アクセシビリティを許可する")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rows.isEmpty {
                EmptyHint(icon: "list.bullet.indent", text: "「更新」で Music.app の\n次に再生リストを読み込みます。")
            } else {
                List(model.rows) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(.system(size: 14)).lineLimit(1)
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Add

struct LibraryTab: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var player: PlayerController
    let mode: Tab

    var body: some View {
        VStack(spacing: 0) {
            if mode == .search {
                if let error = library.searchError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(error).padding(10)
                }
                searchSection
            } else {
                HStack {
                    if library.isLoadingPlaylists { ProgressView().controlSize(.small) }
                    Spacer()
                    Button {
                        if let playlist = library.selectedPlaylist { library.loadTracks(of: playlist) }
                        else { library.loadPlaylists() }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("再読み込み")
                }.padding(.horizontal, 10)
                if let error = library.playlistError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(error).padding(10)
                }
                playlistSection
            }

        }
    }

    @ViewBuilder private var searchSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("", text: $library.query)
                .textFieldStyle(.plain)
                .onChange(of: library.query) { _, _ in library.searchDebounced() }
            if library.isSearching { ProgressView().controlSize(.small) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        .padding(.horizontal, 10)

        if library.results.isEmpty {
            EmptyHint(icon: "magnifyingglass", text: library.isSearching ? "検索中…" : library.query.isEmpty ? "ライブラリから聴きたい曲を探す" : "一致する曲がありません")
        } else {
            List(library.results) { track in
                TrackPickRow(track: track, play: { Task { await player.playNative(track) } })
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder private var playlistSection: some View {
        if let selected = library.selectedPlaylist {
            HStack(spacing: 6) {
                Button { library.selectedPlaylist = nil } label: {
                    Image(systemName: "chevron.left")
                }.buttonStyle(.borderless)
                Text(selected.name).font(.subheadline).bold().lineLimit(1)
                Text("\(library.playlistTracks.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await player.playNativePlaylist(selected.id) }
                } label: { Image(systemName: "play.fill") }
                .help("このプレイリストをMusicで再生")
                .controlSize(.small)
                .disabled(library.playlistTracks.isEmpty)
            }
            .padding(.horizontal, 10).padding(.bottom, 4)

            if library.playlistTracks.isEmpty {
                EmptyHint(icon: library.isLoadingTracks ? "hourglass" : "music.note.list",
                          text: library.isLoadingTracks ? "読み込み中…" : "このプレイリストは空です")
            } else {
                List(library.playlistTracks) { track in
                    TrackPickRow(track: track, play: { Task { await player.playNative(track) } })
                }
                .listStyle(.plain)
            }
        } else if library.playlists.isEmpty {
            EmptyHint(icon: "music.note.list", text: library.isLoadingPlaylists ? "読み込み中…" : "プレイリストが見つかりません")
        } else {
            List(library.playlists) { pl in
                HStack {
                    Image(systemName: "music.note.list").foregroundStyle(.secondary).font(.system(size: 11))
                    Text(pl.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text("\(pl.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { library.loadTracks(of: pl) }
            }
            .listStyle(.plain)
        }
    }
}

struct TrackPickRow: View {
    let track: MusicTrack
    let play: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name).font(.system(size: 13)).lineLimit(1)
                Text(track.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: play) {
                Image(systemName: "play.fill").frame(width: 32, height: 32)
            }.help("再生").accessibilityLabel("再生")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: play)
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
                HStack {
                    Image(systemName: UpNextReader.isTrusted ? "lock.open.fill" : "lock.fill")
                        .foregroundStyle(UpNextReader.isTrusted ? .green : .orange)
                        .frame(width: 28).help("アクセシビリティ")
                    Spacer()
                    if !UpNextReader.isTrusted {
                        Button { UpNextReader.requestTrust() } label: { Image(systemName: "key") }
                            .help("アクセシビリティの許可をリクエスト")
                    }
                }
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
