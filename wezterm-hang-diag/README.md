# wezterm-hang-diag

WezTerm が固まったときの原因調べ用。どちらも読むだけで、何も変更しない。

- `diag-wezterm-hang.ps1`: 応答停止の記録から、何を待って止まったかを出す
- `wezterm-probe.lua`: Lua API の所要時間を測る

## diag-wezterm-hang.ps1

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\diag-wezterm-hang.ps1
```

実行ポリシーで弾かれたら、中身を PowerShell に貼って実行する。

出すもの:

- WezTerm の版と、同梱の `OpenConsole.exe` / `conpty.dll` の日付
- 応答停止の記録（WER の ReportArchive と ReportQueue、イベントログの ID 1002）
- 残っている WezTerm のプロセス数
- セッション、GPU、セキュリティソフト、winget の有無

環境の行にはセキュリティソフトの名前も出るので、どこかに貼るときは消す。

出力例:

```
== WezTerm ==
version: 20240203-110809-5046fc22
OpenConsole.exe  2024-02-03
conpty.dll       2024-02-03

== 応答停止（WER） ==
Date             Type           WaitingOn       Sent
----             ----           ---------       ----
2026-09-09 16:55 AppHangXProcB1 OpenConsole.exe True
2026-09-12 13:02 AppHangXProcB1 OpenConsole.exe True
2026-09-15 22:41 AppHangXProcB1 OpenConsole.exe True
```

## 判定

上から順に当てはめる。記録が複数あるときは 1 件ずつ判定する。

### 1. WER に記録がある

`Type` と `WaitingOn` の組み合わせで決める。

- `AppHangXProcB1` で `WaitingOn` が `OpenConsole.exe`
  - WezTerm の画面が、ペインの ConPTY（`OpenConsole.exe`）の応答を待って止まった
  - 版が `20240203-110809-5046fc22` で `OpenConsole.exe` の日付が `2024-02-03` なら、原因は同梱の古い ConPTY。nightly 版（winget の `wez.wezterm.nightly`）にする
  - nightly 版でも起きるなら、`OpenConsole.exe` と `conpty.dll` を新しい版に 2 つ同時に差し替える（wezterm/wezterm#7774）
  - 設定の Lua を直しても解消しない
- `AppHangXProcB1` で `WaitingOn` が `powershell.exe` か `pwsh.exe`
  - 設定から `wezterm.run_child_process` で起動した PowerShell の終了を待って止まった
  - 設定内の `run_child_process` を `wezterm.background_child_process` にする
- `AppHangXProcB1` で `WaitingOn` がそれ以外
  - そのプロセスを待って止まった。原因がそのプロセス側か WezTerm 側かは、この記録だけでは決まらない
- `AppHangB1`（`WaitingOn` が空）
  - 別のプロセスではなく WezTerm の中で止まった。描画か、設定の Lua の重い処理
  - `session` が `RDP-Tcp` で始まるか、GPU が弱いなら描画を先に疑う。透過（`window_background_opacity`）と Acrylic（`win32_system_backdrop`）を切り、`max_fps` を下げる
  - 変わらなければ `wezterm-probe.lua` で測り、下の目安と比べる

### 2. WER に無く、イベントログにだけ記録がある

WER が無効か、レポートが削除済みだとこうなる。待ち相手の名前は取れない。

- 種別が `Cross-process` なら、別のプロセスを待って止まった。ペインで出力の多いプログラムを動かしていたなら、`OpenConsole.exe` 待ちを先に疑い、1 と同じ対処をする
- `Cross-process` 以外なら、1 の `AppHangB1` と同じ

### 3. どちらにも記録が無い

ID 1002 は、応答しないまま閉じられたときに書かれる。記録が無いのは、固まっても閉じる前に戻ったということ。

- `wezterm-probe.lua` で測り、下の目安と比べる
- 透過と Acrylic を切って変わるかを見る

### ほかの行の読み方

- `Sent` が `False` なのはレポートが送信されていないだけで、判定には使わない
- `wezterm-mux-server` が 1 以上でマルチプレクサを使っていないなら、終了済みの WezTerm の接続先を環境変数に持ったプロセスが `wezterm cli` を呼び、サーバーが残っている。固まった結果であって原因ではない
- `OpenConsole (WezTerm)` が開いているペインより多いなら、過去に固まった WezTerm の配下が残っている。これも結果
- `session` が `RDP-Tcp` で始まるなら、接続と切断のたびにウィンドウの大きさが変わり、全ペインがリサイズされる。固まった時刻が接続や切断と重なるなら、リサイズをきっかけとして疑う
- `security` に Windows Defender 以外があると、プロセス情報の取得やプロセスの起動が遅くなることがある。probe の値が大きければこれを疑う
- `winget` が `なし` なら、nightly 版を winget では入れられない

### この記録から分からないこと

- 固まるきっかけになった操作（分割、ペインを閉じる、リサイズ）は記録されない
- `WaitingOn` は最後に待っていた相手だけで、その相手がなぜ応答しなかったかは分からない

## wezterm-probe.lua

```powershell
& "C:\Program Files\WezTerm\wezterm-gui.exe" --config-file .\wezterm-probe.lua start --always-new-process
```

4 ペイン開いて測り、数秒で終わる。結果は `~/wezterm-probe-result.txt` に追記される。

プロセスが約 580 ある PC での値:

```
pane:get_foreground_process_name()        13 ms
pane:get_current_working_dir()            13 ms
tab:panes_with_info()  [4 panes]          0.01 ms
PaneInformation.foreground_process_name   0.1 ms 未満
```

目安:

- `get_foreground_process_name` と `get_current_working_dir` は、キー入力やベルなど頻繁に起きるイベントから呼ぶと画面を止める。キーリピートは毎秒約 30 回なので、10 ms を超えると押しっぱなしで引っかかり、100 ms を超えると 1 回押すだけで遅れが分かる
- 設定内でこの 2 つを呼んでいる場所のうち、キー入力、`bell`、`update-right-status` から呼ばれるものが対象。前面プロセス名と現在地は、`tab:panes_with_info()` の `foreground_process_name` と `current_working_dir` から読めば軽い
- `tab:panes_with_info()` と `PaneInformation.foreground_process_name` が 1 ms を超えるなら、その PC ではプロセス情報の取得そのものが遅い
