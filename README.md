# MenuQueue

Apple Music をメニューバーから操作する macOS アプリ。
いま流れている曲をメニューバーに出し、クリックで再生操作のパネルを開きます。

## メニューバー

音符アイコンの右に曲名を表示します。長い曲名は10文字ぶんの幅の中を電光掲示板のように
滑らかに流れます（約28pt/秒、各ループの頭で1.2秒止まって先頭を読めるようにしてあります）。
一時停止すると止まって先頭を表示します。アーティストとアルバムはツールチップとパネルに出ます。
「視差効果を減らす」がオンのときは流さず、先頭を表示します。

曲名は一度だけ帯状の画像に描き、Core Animation でずらしているので、動かしている間も
このアプリはほとんど CPU を使いません（位置の計算と描画はウインドウサーバ側で行われます）。

幅はメニューバーを他のアプリと分け合うため最小限にしてあります。収まる曲名なら
その分しか占めず、流れているときだけ幅を固定します（隣の項目がガタつかないように）。
窓の文字数は再ビルドなしで変えられます:

```bash
defaults write jp.local.menuqueue menuBarTitleWidth -int 6
```
一時停止中は淡い色になり、停止中はアイコンだけに戻ります。
マウスを置くとアルバム名まで出ます。

左クリックでパネル、右クリックで簡易メニュー（再生／一時停止・前後の曲・ミュート・
ウインドウで開く・ミュージックを開く・終了）。

## パネル

上段にアートワークと曲名・アーティスト・アルバム、ドラッグできるシークバー。
その下に操作の一列:

| | |
|---|---|
| シャッフル | Music のシャッフルを切り替え |
| 前へ / 再生・一時停止 / 次へ | 連打しても順番に処理します |
| リピート | オフ → すべて → 1曲 |
| ミュート | 音量を0にして元の値を覚え、もう一度押すと戻します |
| 音量 | スライダー。動かすとミュートは解除されます |

下段はプレイリスト。Music で作ったフォルダの階層をそのまま辿れます。
フォルダを開くと中身、プレイリストを開くと曲が並び、← で一段戻ります。
プレイリストの ▶ は全体再生、↻ で読み直します。
曲には左にアルバムのジャケットが出て、再生中の曲にはスピーカーの印が付きます。

**曲をクリックすると、その曲から始めてプレイリストの続きを順に流します。**
Music はスクリプトから曲を1曲指定して再生するとプレイリストの文脈を捨てる
（`current playlist` が空になり、`next track` は同じ曲を頭から流し直すだけ）ため、
プレイリストをアプリ側のキューに積み、曲の終わる0.5秒前に次の曲を渡しています。
キーボードのメディアキー（⏭ ⏮）もキューを進めます。キューで再生している間だけ
キーを横取りし、それ以外は Music にそのまま渡すので、普段の Music の操作は変わりません。
再生／一時停止のキーは横取りしません（Music の一時停止・再開はキュー再生中もそのまま効くため）。
Music.app の画面の「次へ」ボタンだけはキューに届きません。

キューの再生中も Music のリピート設定には触れません。リピートの意味（オフ・すべて・1曲）は
アプリ側のキューがそのまま引き継ぎます。

並び順は Music 本体と同じです。Music の辞書にはプレイリストの日付が無いため、
「追加順」に並べることはできません。

フォルダは `every user playlist` には現れず、誰かの `parent` としてしか見えないので、
`every folder playlist` を別に列挙しています。

ジャケットは画面に出ている行の分だけ取りに行き、アルバム単位でキャッシュします
（1枚あたり約40ms、271曲のプレイリストでもアルバムは84種）。
Music が返すのは原寸（実測1200×1200）なので、36pt のサムネイルに縮小して保持します。

Music に再生中の曲が無いときは再生ボタンを淡く落として無効にします。
その状態では Music 自身の「再生」メニューも無効で、何を送っても鳴らないためです。
プレイリストを選んで ▶ で再生を始められます。

パネルはクリックした画面のメニューバー直下に開き、その画面の表示可能領域に収まります。
画面外クリックか Escape で閉じます。右クリックの「ウインドウで開く」で常設表示もできます。

高さは 470pt（操作部と一覧数行ぶん）。メニューバーから下に伸びるので控えめにしてあります。
変えたいときは再ビルド不要です:

```bash
defaults write jp.local.menuqueue panelHeight -int 560
```

## 許可

| 許可 | 用途 | 無いと |
|---|---|---|
| オートメーション（Music.app） | 再生情報の取得と操作すべて | 何も動きません |
| アクセシビリティ | キュー再生中にメディアキー（⏭ ⏮）を横取りする | メディアキーは Music に届き、同じ曲の頭に戻るだけになります |

アクセシビリティは設定（歯車）の「メディアキー」行の「許可」から求められます。
システム設定で許可すると、アプリを再起動しなくても数秒で有効になります。

### 署名と許可

`build.sh` はログインキーチェーンに `MenuQueue Local Signing` というコード署名用証明書が
あればそれで署名します。すると許可の照合に使われる指定要件が

```
identifier "jp.local.menuqueue" and certificate leaf = H"…"
```

と**証明書に紐づく**ので、ソースを変えて再ビルドしても許可は残ります。
証明書が無いと ad-hoc 署名になり、要件がバイナリのハッシュに紐づくため、
再ビルドのたびに両方の許可が無効になります（システム設定上はオンのまま見えるのに効かない状態）。

証明書はこのマシン専用の自己署名で、キーチェーンで「信頼」する設定は入れていません。
署名には信頼は不要で、要件は証明書そのものを指すためです。作り方:

```bash
cat > cert.cnf <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = MenuQueue Local Signing
[ ext ]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem -config cert.cnf
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "MenuQueue Local Signing" -out id.p12 -passout pass:tmp
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
rm key.pem id.p12
```

ad-hoc から証明書に切り替えた直後の1回だけは、記録を消して許可し直す必要があります:
`tccutil reset AppleEvents jp.local.menuqueue` / `tccutil reset Accessibility jp.local.menuqueue`
`build.sh` は `MenuQueue Local Signing` という名前のコード署名証明書があれば
そちらを使い、許可が再ビルドをまたいで残るようにします。

## ビルド・インストール

macOS 14 以降、Music.app、Xcode Command Line Tools が必要です。

```bash
./build.sh
open build/MenuQueue.app
```

インストールは起動中の MenuQueue を終了してから:

```bash
mkdir -p ~/Applications
cp -R build/MenuQueue.app ~/Applications/
open ~/Applications/MenuQueue.app
```

設定の電源アイコンでログイン時起動を切り替えられます。
実行ファイルに `--register-login-item` / `--unregister-login-item` でも切り替えられ、
`--window` を付けると常設ウインドウを開きます。

## 検証

```bash
./build.sh  # AppleScript構文チェック、Swiftコンパイル、署名
./test.sh   # ユーザーのMusic再生を変えない回帰テスト
```

`check_scripts.py` が `Sources/*.swift` の AppleScript リテラルを `osacompile` に通します。
Music.app の辞書は `st` や `prop` のような短い識別子を予約語として奪うため、
素直な変数名は実行時まで気づけないエラーになります。ビルド時に落とすための検査です。

回帰テストはテスト用 Music アダプターを使い、曲送り・シャッフルの連打、遅い応答、
古い状態の取得、失敗からの復旧、ミュートの記憶と復元、リピート借用の返却、
キューの並べ替えと永続化、ライブラリ索引の解析を検証します。
パネル配置は5種類のディスプレイ配置と左右端で検証します。

`Tests/MusicReadCheck.swift` は Music から読み取るだけの実機確認用です。
実際の音声再生と複数画面の実機動作は自動テストの対象外です。

## できないこと

**Music のキューへの追加・並べ替えはできません。**

- AppleScript の辞書に「次に再生（Up Next）」が存在しません（`sdef` で確認できます）
- アクセシビリティ経由でツールバーのメニューを叩く方法は、macOS 26 では
  Music のツールバーが子要素を一切公開しない（`AXToolbar kids=0`）ため成立しません
- `view of front browser window` からプレイリストの persistent ID も取得できません

以前あったキュー表示タブと「キューに追加」ボタンはこの理由で撤去しました。
キューの操作は Music.app 本体で行ってください。

## 内部メモ

- ライブラリ検索は `LibraryIndex` が全プレイリストを1往復で読み込み、Swift 側で照合します。
  Music の `search` 動詞はローカル保存の曲しか見ないため、iCloud ライブラリでは
  ほとんど何も見つかりません（実測で20曲中0曲）。
- クラウド曲（`shared track`）は `library playlist 1` に存在しません。
  再生は所属プレイリストを容器にして `database ID` で引きます。
- 空のプレイリストは `every track` が `{}` を返す一方 `database ID of every track` が
  エラーになるため、件数0を先に判定しています。
- 旧版の独自キューの保存データとモデルは互換性のため残していますが、現在の画面からは
  使いません。ユーザーの保存済みデータは削除しません。
