# navi — My-AHK-Scripts の Navi を別の PC で試すための写し

[My-AHK-Scripts](https://github.com/Taka-S-dev/my-ahk-scripts) の `feat/navi-list` ブランチ（`0b3d5cd`）にある Navi（フォルダナビゲーター）をそのまま写したもの。
別の PC でしばらく使って問題がなければ、本体のリポジトリの方を push する。ここで直したところは本体にも戻す。

main から増えたもの:

- 一覧表示（`Ctrl+E`、`Shift+Tab` でフォルダ ↔ ファイル）とあいまい検索
- 3 列ブラウズ（`Ctrl+B`）。`←` `→` で上がる・入る。`Ctrl+Shift+B` で今のフォルダをルートとして開く
  - エクスプローラーと同じ戻る・進む・上へ（パスの左のボタン、`Alt+←/→/↑`、マウスの戻る／進む）
  - クリックでも上がれる（左の列の見出し・ダブルクリック、パスのクリックで上の階層のメニュー）
  - 開いている場所はタブごとに覚え、Navi を開き直しても続きから
- 表示の切り替えボタン（パスの行の右端。ツリー／一覧／3 列）
- タブの閉じる `×`
- ルートがネットワーク上（`\\server\share` やネットワークドライブ）なら、一覧を作る前に確認する。裏での先読みや fd もしない
- コマンド一覧（`Ctrl+;`）、`Ctrl+H/J/K/L` の矢印、見た目の統一（アイコン、角丸のメニュー、タブ）

キーの一覧は Navi の中で `F1`。

## 中身

| ファイル | 役目 |
|---|---|
| `ui/navi/*.ahk` | Navi 本体（本体リポジトリの `ui/navi/` と同じ） |
| `lib/TempCopy.ahk` | Navi が読み込む部品（本体リポジトリの `lib/` から） |
| `NaviStandalone.ahk` | My-AHK-Scripts なしで Navi だけを動かすランチャー |

## 別の PC で試す

AutoHotkey v2 が要る。

- **Navi だけで試す**: `NaviStandalone.ahk` を実行する。`Ctrl+Alt+F` で開く（もう一度押すと最小化）。
  初回は初期設定の画面が出る。設定は `ui/navi/Navi.ini` にでき、git には入らない
- **いつもの My-AHK-Scripts で試す**: その PC の My-AHK-Scripts の `ui/navi/` に `ui/navi/*.ahk` を上書きしてリロードする。
  `無変換+F` で開く。戻すときは `git checkout -- ui/navi`
