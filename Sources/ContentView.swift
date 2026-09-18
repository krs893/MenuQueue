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
    case upNext = "Up Next"
    case add = "追加"
    var id: String { rawValue }
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
            Divider()

            if showSettings {
                SettingsPanel(player: player, store: store, close: { showSettings = false })
            } else {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Group {
                    switch tab {
                    case .queue:  QueueTab(player: player, store: store)
                    case .upNext: UpNextTab(model: upNext)
                    case .add:    AddTab(library: library, store: store, player: player)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let err = player.lastError {
                Divider()
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 390, height: 600)
        .onAppear {
            library.loadPlaylists()
            if tab == .upNext { upNext.refresh() }
        }
        .onChange(of: tab) { _, newValue in
            if newValue == .upNext && upNext.rows.isEmpty { upNext.refresh() }
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
                        Text("ミュージックが起動していません").font(.system(size: 13, weight: .semibold))
                        Button("起動する") { player.launchMusic() }
                            .buttonStyle(.link).font(.caption)
                    } else if let t = player.now.track {
                        Text(t.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(t.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("再生していません").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    if player.owns {
                        Label("キュー再生中", systemImage: "list.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.tint)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: showSettings ? "xmark.circle" : "gearshape")
                }
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
        .frame(width: 52, height: 52)
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
                Text(timeString(value)).font(.system(size: 9, design: .monospaced))
                Spacer()
                Text("-" + timeString(max(duration - value, 0))).font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct TransportBar: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        HStack(spacing: 14) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.shuffleIsOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .help(player.shuffleTargetsQueue
                  ? "キューをシャッフル（並びはキュータブに反映されます）"
                  : "Music.app のシャッフル")

            Button { player.previous() } label: { Image(systemName: "backward.fill") }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.now.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }

            Button { player.cycleRepeat() } label: {
                Image(systemName: player.now.repeatMode == "one" ? "repeat.1" : "repeat")
                    .foregroundStyle(player.now.repeatMode == "off" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .help("リピート")

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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(store.items.count) 曲").font(.caption).foregroundStyle(.secondary)
                if store.shuffleActive {
                    Label("シャッフル", systemImage: "shuffle")
                        .font(.system(size: 9))
                        .foregroundStyle(.tint)
                    Button { store.reshuffle() } label: { Image(systemName: "arrow.clockwise") }
                        .help("引き直す")
                }
                Spacer()
                Button {
                    Task { await player.startQueueFromTop() }
                } label: { Label("先頭から", systemImage: "play.fill") }
                    .disabled(store.items.isEmpty)
                Menu {
                    Button("これ以降をクリア") { store.clearUpcoming() }
                    Button("全部消す", role: .destructive) { store.clearAll() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 26)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            if !player.owns && player.now.state.isPlaying {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                    Text("いまは Music.app 自身が再生を進めています。この並びはまだ使われていません。Music.app 側のシャッフル順は「Up Next」タブでのみ見えます。")
                        .font(.system(size: 10))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 6)
            }

            if store.items.isEmpty {
                EmptyHint(icon: "text.badge.plus",
                          text: "キューは空です。\n「追加」タブから曲を入れてください。")
            } else {
                List {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                        QueueRow(index: index, item: item,
                                 isCurrent: item.id == store.currentID,
                                 isPast: isPast(index))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { Task { await player.play(item: item) } }
                            .contextMenu {
                                Button("今すぐ再生") { Task { await player.play(item: item) } }
                                Button("次に再生へ移動") { moveToNext(item) }
                                Divider()
                                Button("削除", role: .destructive) { store.remove(ids: [item.id]) }
                            }
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
            }
        }
    }

    private func isPast(_ index: Int) -> Bool {
        guard let current = store.currentIndex else { return false }
        return index < current
    }

    private func moveToNext(_ item: QueueItem) {
        guard let from = store.items.firstIndex(where: { $0.id == item.id }) else { return }
        let target = (store.currentIndex.map { $0 + 1 }) ?? 0
        guard from != target else { return }
        store.move(from: IndexSet(integer: from), to: from < target ? target : target)
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
                Text(item.track.name).font(.system(size: 12)).lineLimit(1)
                Text(item.track.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(timeString(item.track.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
        }
        .opacity(isPast ? 0.45 : 1)
        .padding(.vertical, 2)
    }
}

// MARK: - Up Next (read-only, via Accessibility)

struct UpNextTab: View {
    @ObservedObject var model: UpNextModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Music.app の「次に再生」").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.loading)
            }
            .padding(.horizontal, 10).padding(.bottom, 6)

            if let err = model.error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
                    Text(err).font(.caption).multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                    if !UpNextReader.isTrusted {
                        Button("アクセシビリティを許可する") { UpNextReader.requestTrust() }
                            .controlSize(.small)
                    }
                    Text("※ 読み取り専用です。Music.app の Up Next は\nAppleScript で公開されていないため、\n並べ替えは「キュー」タブを使ってください。")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var mode = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text("検索").tag(0)
                Text("プレイリスト").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.bottom, 6)

            if mode == 0 { searchSection } else { playlistSection }
        }
    }

    @ViewBuilder private var searchSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("ライブラリを検索", text: $library.query)
                .textFieldStyle(.plain)
                .onChange(of: library.query) { _, _ in library.searchDebounced() }
            if library.isSearching { ProgressView().controlSize(.small) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        .padding(.horizontal, 10)

        if library.results.isEmpty {
            EmptyHint(icon: "magnifyingglass", text: "曲名・アーティスト名で検索")
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
                Text(selected.name).font(.caption).bold().lineLimit(1)
                Spacer()
                Button("全部追加") { store.append(library.playlistTracks) }
                    .controlSize(.small)
                    .disabled(library.playlistTracks.isEmpty)
                Button("これを再生") {
                    store.replaceAll(with: library.playlistTracks)
                    Task { await player.startQueueFromTop() }
                }
                .controlSize(.small)
                .disabled(library.playlistTracks.isEmpty)
            }
            .padding(.horizontal, 10).padding(.bottom, 4)

            if library.playlistTracks.isEmpty {
                EmptyHint(icon: "hourglass", text: "読み込み中…")
            } else {
                List(library.playlistTracks) { track in
                    TrackPickRow(track: track,
                                 addEnd: { store.append([track]) },
                                 addNext: { store.playNext([track]) })
                }
                .listStyle(.plain)
            }
        } else if library.playlists.isEmpty {
            EmptyHint(icon: "music.note.list", text: "プレイリストが見つかりません")
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

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name).font(.system(size: 12)).lineLimit(1)
                Text(track.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: addNext) { Image(systemName: "text.insert") }
                .help("次に再生")
            Button(action: addEnd) { Image(systemName: "plus") }
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
            Image(systemName: icon).font(.title2).foregroundStyle(.tertiary)
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
                Toggle("ログイン時に起動", isOn: $loginItemOn)
                    .onChange(of: loginItemOn) { _, newValue in
                        loginItemError = LoginItem.set(newValue)
                        loginItemOn = LoginItem.isEnabled
                    }
                if let e = loginItemError {
                    Text(e).font(.system(size: 10)).foregroundStyle(.red)
                } else if SMAppService.mainApp.status == .requiresApproval {
                    Text("システム設定 › 一般 › ログイン項目 で承認してください。")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }

                Divider()

                Toggle("再生済みの曲をキューから消す", isOn: $store.consumeOnPlay)
                Toggle("曲の切れ目を詰める（再生中はリピート1を借用）", isOn: $player.gaplessTakeover)
                Text("Music.app には「次に再生」を操作する AppleScript が無いため、このアプリは自前のキューを持ち、1曲ずつ Music.app に渡しています。曲の終わりで次に移る間、Music.app が勝手に別の曲へ進まないようリピート1を一時的に使います（キューを離れると元に戻します）。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Text("アクセシビリティ").font(.caption).bold()
                    Spacer()
                    Text(UpNextReader.isTrusted ? "許可済み" : "未許可")
                        .font(.caption).foregroundStyle(UpNextReader.isTrusted ? .green : .orange)
                }
                Text("Music.app の Up Next を読むのに使います。").font(.system(size: 10)).foregroundStyle(.secondary)
                if !UpNextReader.isTrusted {
                    Button("許可をリクエスト") { UpNextReader.requestTrust() }.controlSize(.small)
                }

                Divider()
                HStack {
                    Button("閉じる", action: close).controlSize(.small)
                    Spacer()
                    Button("MenuQueue を終了") { NSApp.terminate(nil) }
                        .controlSize(.small)
                }
            }
            .padding(14)
        }
    }
}
