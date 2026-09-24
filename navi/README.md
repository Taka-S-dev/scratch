# navi — My-AHK-Scripts の Navi を別の PC で試すための写し

[My-AHK-Scripts](https://github.com/Taka-S-dev/my-ahk-scripts) の `feat/navi-list` ブランチ（`956c758`）にある Navi（フォルダナビゲーター）をそのまま写したもの。
別の PC でしばらく使って問題がなければ、本体のリポジトリの方を push する。ここで直したところは本体にも戻す。

main から増えたもの:

- 一覧表示（`Ctrl+E`、`Shift+Tab` でフォルダ ↔ ファイル）とあいまい検索
- 3 列ブラウズ（`Ctrl+B`）。`←` `→` で上がる・入る。`Ctrl+Shift+B` で今のフォルダを一時的なルートにしてツリーで表示
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
