# MenuQueue

メニューバーから音楽を操作する macOS アプリです。再生中の曲名をメニューバーに流し、
クリックで開くパネルから再生操作・音量・キューの確認ができます。聴いている曲を
Discord のアクティビティに出すこともできます。

**YouTube Music 版**と **Apple Music 版**があります。使っているほうを選んでください。

| | YouTube Music 版 | Apple Music 版 |
|---|---|---|
| 対象 | Chrome で開いた YouTube Music（Chrome でインストールしたアプリ版も可） | macOS の「ミュージック」アプリ |
| メニューバーに曲名（長い曲名は流れる） | ✓ | ✓ |
| 再生・一時停止・前後・シーク・音量・ミュート | ✓ | ✓ |
| キューの表示とジャンプ | ✓（YouTube Music の「次に再生」一覧） | ―（プレイリストから選んで、その曲から順に再生） |
| Discord に「〇〇を再生中」 | ✓ | ✓ |
| ソース | `main` ブランチ | `apple-music` ブランチ |

## ダウンロードとインストール

1. [Releases](../../releases) から使うほうの zip をダウンロードして展開します
   - `MenuQueue-YouTubeMusic.zip`
   - `MenuQueue-AppleMusic.zip`
2. `MenuQueue.app` を「アプリケーション」フォルダに入れます
3. 初回だけ、**右クリック → 開く** で起動してください

   開発元の登録（Apple の公証）をしていない個人製作のアプリなので、ダブルクリックだと
   「開けません」と表示されます。右クリック → 開く → 「開く」で一度許可すれば、
   次からは普通に起動できます。それでも開けない場合は、ターミナルで次を実行してください。

   ```bash
   xattr -dr com.apple.quarantine /Applications/MenuQueue.app
   ```

Intel と Apple Silicon の両方で動きます。macOS 14 以降が必要です。
2つの版は同じアプリとして扱われるので、どちらか一方だけを入れてください。

## YouTube Music 版の準備

YouTube Music のページを読み取るため、Chrome の設定を1つオンにします。

1. Chrome のメニューバーで **［表示］→［開発 / 管理］→［Apple Events からの JavaScript を許可］**
   をクリックしてチェックを入れる
2. MenuQueue を起動すると「MenuQueue が Google Chrome を制御しようとしています」と出るので **許可**

> この設定は Chrome 全体に効きます。オンにすると、Chrome を操作する許可を持つアプリは、
> 開いているページ（ログイン中のサイトを含む）で JavaScript を実行できるようになります。
> MenuQueue が触るのは `music.youtube.com` のタブだけです。

YouTube Music のタブ（またはアプリ版のウインドウ）で曲を再生すれば、メニューバーに曲名が出ます。
タブが複数あるときは、再生中のタブに従います。メディアキー（⏯ ⏭ ⏮）は Chrome が
そのまま対応しているので、追加の設定は要りません。

## Apple Music 版の準備

起動すると「MenuQueue が ミュージック を制御しようとしています」と出るので **許可** してください。
キュー再生中にキーボードのメディアキーでも曲送りしたい場合だけ、設定（歯車）の
「メディアキー」からアクセシビリティを許可します。

## 使い方

- **左クリック**: パネルを開く（曲・操作・キュー）。外をクリックか Esc で閉じる
- **右クリック**: 再生／一時停止・前後の曲・アプリを開く・終了
- パネルの歯車から、ログイン時の自動起動と Discord 表示を切り替えられます

調整用の設定（ターミナルで実行し、アプリを再起動）:

```bash
defaults write jp.local.menuqueue menuBarTitleWidth -int 8   # メニューバーの曲名の文字数（既定 10）
defaults write jp.local.menuqueue panelHeight -int 560       # パネルの高さ（既定 470）
```

## Discord 表示について

Discord アプリが起動していれば、再生中の曲を「〇〇を再生中」として表示します
（一時停止で消えます）。表示に使う Discord アプリケーションは、
YouTube Music 版が [pear-devs/pear-desktop](https://github.com/pear-devs/pear-desktop)、
Apple Music 版が [NextFire/apple-music-discord-rpc](https://github.com/NextFire/apple-music-discord-rpc)
が公開しているものを借りています。自分のものに替える場合:

```bash
defaults write jp.local.menuqueue discordClientID <アプリケーションID>
```

Apple Music 版はジャケット画像を Apple の公開検索 API で探すため、曲名・アーティスト名・
アルバム名が Apple に送られます。YouTube Music 版はページにある画像をそのまま使います。

## ソースからビルド

Xcode Command Line Tools があれば、Xcode プロジェクトなしでビルドできます。

```bash
./build.sh            # このMac向け
RELEASE=1 ./build.sh  # 配布用（Intel + Apple Silicon、ad-hoc 署名）
./test.sh             # テスト
```

## 仕組み（YouTube Music 版）

Chrome の AppleScript の `execute javascript` で YouTube Music のページを読み書きしています。
このスクリプトはページとは分離された環境で動き、ページ自身の JavaScript には触れられず、
スクリプトの差し込みも Trusted Types で拒否されます。ただし画面の要素（DOM）は共有されているので、
プレーヤーバー・キュー・`<video>` 要素から状態を読み、操作はページ自身のボタンや音量スライダーを
押す形で行います。人が操作するのと同じ経路なので、YouTube Music 側の状態も正しく保たれます。

## ライセンス

[MIT](LICENSE)
