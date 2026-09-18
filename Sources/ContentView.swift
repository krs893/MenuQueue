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
    case add = "曲を追加"
    case upNext = "Musicの次に再生"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .queue: return "list.bullet"
        case .add: return "plus.circle"
        case .upNext: return "music.note.list"
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
                    case .queue:  QueueTab(player: player, store: store, addTracks: { tab = .add })
                    case .upNext: UpNextTab(model: upNext)
                    case .add:    AddTab(library: library, store: store, player: player, showQueue: { tab = .queue })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let err = player.lastError ?? store.persistenceError {
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
            if newValue == .add { library.loadPlaylists() }
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

// MARK: - Queue

struct QueueTab: View {
    @ObservedObject var player: PlayerController
    @ObservedObject var store: QueueStore
    let addTracks: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet").foregroundStyle(.secondary)
                Text("\(store.items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                if store.shuffleActive {
                    Image(systemName: "shuffle").help("シャッフル")
                        .font(.system(size: 9))
                        .foregroundStyle(.tint)
                    Button { store.reshuffle() } label: { Image(systemName: "arrow.clockwise") }
                        .help("引き直す")
                }
                Spacer()
                Button {
                    Task { await player.startQueueFromTop() }
                } label: { Image(systemName: "play.fill").frame(width: 24, height: 20) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.items.isEmpty)
                Menu {
                    Button("次に流れる曲をすべて削除") { store.clearUpcoming() }
                    Button("キューを空にする", role: .destructive) { Task { await player.clearQueue() } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 26)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            if store.items.isEmpty {
                Button(action: addTracks) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 46, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                }.buttonStyle(.plain).help("曲を追加")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                        QueueRow(index: index, item: item,
                                 isCurrent: player.owns && item.id == store.currentID,
                                 isPast: isPast(index))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { Task { await player.play(item: item) } }
                            .contextMenu {
                                Button("今すぐ再生") { Task { await player.play(item: item) } }
                                Button("次に再生へ移動") { moveToNext(item) }
                                    .disabled(item.id == store.currentID)
                                Divider()
                                Button("削除", role: .destructive) { store.remove(ids: [item.id]) }
                                    .disabled(item.id == store.currentID)
                            }
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                Divider()
                HStack {
                    Image(systemName: "hand.draw")
                        .foregroundStyle(.tertiary).help("ドラッグで並べ替え、ダブルクリックで再生")
                    Spacer()
                    Button(action: addTracks) { Image(systemName: "plus").frame(width: 28, height: 24) }.help("曲を追加")
                        .buttonStyle(.borderedProminent)
                }.padding(10)
            }
        }
    }

    private func isPast(_ index: Int) -> Bool {
        guard player.owns, let current = store.currentIndex else { return false }
        return index < current
    }

    private func moveToNext(_ item: QueueItem) {
        guard let from = store.items.firstIndex(where: { $0.id == item.id }) else { return }
        let target = (store.currentIndex.map { $0 + 1 }) ?? 0
        guard from != target else { return }
        store.move(from: IndexSet(integer: from), to: target)
    }
}

struct QueueRow: View {
    let index: Int
    let item: QueueItem
    let isCurrent: Bool
    let isPast: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                } else {
                    Text("\(index + 1)").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.track.name).font(.system(size: 14, weight: isCurrent ? .semibold : .regular)).lineLimit(1)
                Text(item.track.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(timeString(item.track.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
        }
        .opacity(isPast ? 0.65 : 1)
        .padding(.vertical, 6)
    }
}

// MARK: - Up Next (read-only, via Accessibility)

struct UpNextTab: View {
    @ObservedObject var model: UpNextModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "eye").foregroundStyle(.secondary).help("Music側のキュー・読み取り専用")
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
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
                        Text(row.title).font(.system(size: 12)).lineLimit(1)
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Add

struct AddTab: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var store: QueueStore
    @ObservedObject var player: PlayerController
    let showQueue: () -> Void
    @State private var mode = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Image(systemName: "magnifyingglass").help("検索").tag(0)
                Image(systemName: "music.note.list").help("プレイリスト").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.bottom, 6)

            if mode == 0 {
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
            Divider()
            HStack {
                Image(systemName: "list.bullet").foregroundStyle(.secondary)
                Text("\(store.items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button(action: showQueue) { Image(systemName: "arrow.right").frame(width: 28, height: 24) }.buttonStyle(.bordered).help("キューを見る")
            }.padding(10)
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
                TrackPickRow(track: track,
                             addEnd: { store.append([track]) },
                             addNext: { store.playNext([track]) })
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
                Button { store.append(library.playlistTracks) } label: { Image(systemName: "text.badge.plus") }
                    .help("すべてキューに追加")
                    .controlSize(.small)
                    .disabled(library.playlistTracks.isEmpty)
                Button {
                    Task { await player.replaceQueue(with: library.playlistTracks) }
                } label: { Image(systemName: "play.fill") }
                .help("このプレイリストでキューを置き換えて再生")
                .controlSize(.small)
                .disabled(library.playlistTracks.isEmpty)
            }
            .padding(.horizontal, 10).padding(.bottom, 4)

            if library.playlistTracks.isEmpty {
                EmptyHint(icon: library.isLoadingTracks ? "hourglass" : "music.note.list",
                          text: library.isLoadingTracks ? "読み込み中…" : "このプレイリストは空です")
            } else {
                List(library.playlistTracks) { track in
                    TrackPickRow(track: track,
                                 addEnd: { store.append([track]) },
                                 addNext: { store.playNext([track]) })
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
    let addEnd: () -> Void
    let addNext: () -> Void
    @State private var added = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name).font(.system(size: 13)).lineLimit(1)
                Text(track.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { addNext(); added = true } label: { Image(systemName: "text.insert").frame(width: 28, height: 28) }
                .help("次に再生")
            Button { addEnd(); added = true } label: {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle").font(.system(size: 18)).frame(width: 32, height: 32)
            }
                .help("キューの最後に追加")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
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
                    Image(systemName: "trash").frame(width: 28).help("再生済みの曲を削除")
                    Spacer()
                    Toggle("再生済みの曲を削除", isOn: $store.consumeOnPlay).labelsHidden()
                }
                HStack {
                    Image(systemName: "forward.end").frame(width: 28).help("曲の切り替えを安定させる")
                    Spacer()
                    Toggle("曲の切り替えを安定させる", isOn: $player.gaplessTakeover).labelsHidden()
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
