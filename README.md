# MenuQueue

Apple Music をメニューバーから操作する常駐アプリ。再生中の曲、シーク、音量、
そして **GUI で並べ替えられるキュー**をメニューバーのポップオーバーに出します。

```bash
./build.sh && open build/MenuQueue.app
```

Xcode プロジェクトは不要。`swiftc` だけでビルドします。
インストール先は `~/Applications/MenuQueue.app`、ログイン時の自動起動は
設定パネル（歯車アイコン）の「ログイン時に起動」で切り替えられます。
スクリプトから切るなら:

```bash
~/Applications/MenuQueue.app/Contents/MacOS/MenuQueue --unregister-login-item
```

## なぜ「自前キュー」なのか

Music.app の AppleScript 辞書には **Up Next（次に再生）が存在しません**。
`sdef /System/Applications/Music.app` を見ても `next track` コマンドがあるだけで、
キューの中身を読む・並べ替えるための語彙は一切公開されていません。

そこで MenuQueue は自分でキューを持ち、Music.app には 1 曲ずつ渡します。
曲の終わりで Music.app が勝手に別の曲へ進んでしまわないよう、キューを再生中は
**リピート1 を一時的に借用**し（曲末でループさせて）、その隙に次の曲を投げます。
キューから手を離すと元のリピート設定に戻します。この挙動は設定でオフにできます。

曲末 4 秒を切ったらポーリングを 100ms に詰めているので、切り替わりの間は
おおむね 0.1〜0.3 秒です。

## できること

| | |
|---|---|
| 再生情報 | 曲名・アーティスト・アルバム・アートワーク・再生位置 |
| 操作 | 再生/一時停止・前後・シーク・音量・シャッフル・リピート |
| キュー | ドラッグで並べ替え、削除、ダブルクリックで即再生、「次に再生」へ割り込み |
| シャッフル | キュー自体を並べ替える（結果が目に見えるし、そこからさらに手で動かせる）。オフで元の順番に復元 |
| 追加 | ライブラリ検索、プレイリストから曲単位／まるごと追加 |
| Up Next | Music.app 側の「次に再生」をアクセシビリティ経由で読み取り（表示のみ） |

メニューバーアイコンを **右クリック**すると再生/停止・曲送り・終了のメニューが出ます。

## 必要な許可

* **オートメーション** — 初回に「MenuQueue が Music.app を制御しようとしています」が出ます。許可してください。
* **アクセシビリティ** — Up Next タブだけで使います。許可しなくてもキュー機能は全部動きます。

ビルドは `codesign --sign -` で固定の識別子 `jp.local.menuqueue` を付けて ad-hoc 署名しています。
ただし ad-hoc 署名の同一性判定にはバイナリのハッシュも効くため、**ソースを変えて再ビルドすると
オートメーションの許可をもう一度聞かれることがあります**。その場合は素直に許可してください。

## シャッフルの扱い

Music.app 側のシャッフル設定は、MenuQueue がキューを握っている間は**何の効果もありません**。
1 曲ずつ渡している以上、Music.app には並べ替える対象が無いからです。

なのでシャッフルボタンは、キューに曲が入っているときは**キュー自身をシャッフル**します。
再生中の曲より後ろだけを混ぜ、結果はキュータブにそのまま並びます。つまり
「シャッフルされた順番を目で見て、気に入らないところだけ手で動かす」ができます。
オフに戻すと元の順番に復元します（シャッフル中に足した曲は末尾に残ります）。
`⟳` ボタンで引き直しもできます。

キューが空のときだけ、ボタンは従来どおり Music.app のシャッフルを切り替えます。

逆に **Music.app 自身がシャッフル再生を進めている場合**、その並びは AppleScript からは
読めません。この状態ではキュータブにその旨のバナーが出ます。シャッフル後の実際の順番を
見たいなら「Up Next」タブ（アクセシビリティ読み取り）を使ってください。

## Up Next タブの注意

Music.app の Up Next はポップオーバーが開いている間しか存在しないため、
「更新」を押すと MenuQueue が一瞬そのポップオーバーを開いて読み、閉じます。
Apple が UI を変えると壊れる類の実装です。並べ替えたいときは「キュー」タブを使ってください。

## YouTube Music について

`/Applications/YTMusic.app`（`com.kdrgny.ytmusicmac`）は WKWebView のラッパーで、
AppleScript もローカル API も持っていないため外から操作できません。
YouTube Music を Google Chrome のタブで再生すれば、Chrome の
`execute javascript` 経由でキューの読み取り・並べ替え・任意の曲へのジャンプまで可能です
（Chrome の「開発」メニューで *Apple Events からの JavaScript を許可* が必要）。
今回は対象外にしていますが、後から足せる構造にしてあります。

## ファイル

| | |
|---|---|
| `Sources/MusicBridge.swift` | AppleScript で Music.app と会話する層 |
| `Sources/QueueStore.swift` | キューのモデルと永続化（`~/Library/Application Support/MenuQueue/queue.json`） |
| `Sources/PlayerController.swift` | ポーリングと自動送りのエンジン |
| `Sources/UpNextReader.swift` | アクセシビリティによる Up Next 読み取り |
| `Sources/ContentView.swift` | ポップオーバーの UI |
| `Sources/main.swift` | `NSStatusItem` と常駐まわり |
| `check_scripts.py` | AppleScript リテラルを `osacompile` で構文チェック（`build.sh` から実行） |

`check_scripts.py` があるのは、Music.app の辞書が `st` のような短い識別子を
予約語として奪うため。変数名を素朴に付けると実行時に初めて落ちます。
