# td — Win+R から tadoru を WezTerm で開くランチャー

`Win+R` → `td` → Enter で、WezTerm のタブに [tadoru](https://github.com/Taka-S-dev/tadoru) が開く。
フォルダを選んで Enter を押すと、そのフォルダで PowerShell が開き、tadoru は閉じる。

- WezTerm のウィンドウがあればそこに新しいタブとして開く(最小化していても前面に出す)。なければ新しいウィンドウ
- 引数で開き方を変えられる: `td browse`、`td memo`(お気に入りの名前)、`td C:\work`、`td files memo`
- Ctrl-P のアクションメニューでアクションを 1 つ実行すると tadoru は閉じる(`--after-action quit`)。
  続けて使いたいときはメニューで Ctrl-X を押すと、その起動中は閉じなくなる

## 中身

| ファイル | 役目 |
|---|---|
| `td.js` | ランチャー本体。wscript で動く JScript |
| `config/actions.json` | tadoru のアクション定義。Enter で起動する「PowerShell here」はここで定義している(組み込みの「Open shell here」は cmd.exe を開くため) |
| `install.ps1` | `td.lnk` を作る。Win+R の `td` はこのショートカットを探す |

## 別の PC で使うまで

1. **WezTerm** を入れる。`C:\Program Files\WezTerm\` にあること(td.js に固定で書いてある。別の場所なら `wezDir` を直す)
2. **PowerShell 7**(`pwsh`)を入れる。Enter で開くシェルがこれ。Windows 標準の 5.1 だけでよければ `config/actions.json` の `"program": "pwsh"` を `"powershell"` にする
3. フォルダを作ってこの 3 つを置く。例: `C:\Users\<自分>\tadoru\`
   ```
   tadoru\
     td.js
     install.ps1
     config\actions.json
   ```
4. **tadoru.exe** を同じフォルダに置く(tadoru リポジトリを `cargo build --release` した `target\release\tadoru.exe`)。td.js は自分の隣の exe を使う
5. そのフォルダを **PATH** に追加する。Win+R はここから `td.lnk` を見つける
6. `install.ps1` を実行する。`td.lnk` ができる
   ```powershell
   pwsh -File C:\Users\<自分>\tadoru\install.ps1
   ```
7. `Win+R` → `td` → Enter で開けば完了

tadoru 自体のセットアップ(シェルの `c` `cf` `z` `zi` 関数)は別。tadoru リポジトリの README の手順で `tadoru setup` を実行する。それをしなくても td は動く。

## 自分の使い方に合わせる

td.js の先頭付近を直す。

- 引数なしの `td` で開くフォルダ: `var root = home + "\\folder\\work"` の行。無ければホームで開く
- Enter で起動するもの: `var onAccept = "PowerShell here"`。actions.json に書いたアクション名か、組み込みの `"Open shell here"`
- お気に入りに名前を付けておくと `td 名前` で開ける。名前は tadoru の画面で Ctrl-N、または `tadoru favorite add --name 名前 フォルダ`

## 動かないとき

`%TEMP%\td.log` に毎回の手順が残る(見つけたソケット、どのウィンドウに開いたか、新規に開いたか)。
何も起きないときはまずこれを見る。

- `process has no window` が続く: ウィンドウのない wezterm-gui プロセスが残っている。タスクマネージャーで wezterm-gui を終了する
- 新しいウィンドウで開いてしまう: 既存のウィンドウが応答しなかった。上と同じ
- `no favorite named :xxx`: その名前のお気に入りがない。`tadoru favorite list` で確認

## 仕組みの注意

- WezTerm は自分のウィンドウを `%USERPROFILE%\.local\share\wezterm\gui-sock-<pid>` のソケットで見つける。td.js は生きている wezterm-gui のソケットだけを新しい順に試す
- ウィンドウの有無と前面への表示は PowerShell(5.1)で Win32 API を呼んで行うため、起動に 1 秒ほどかかる
