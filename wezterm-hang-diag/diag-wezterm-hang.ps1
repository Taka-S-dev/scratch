# WezTerm の応答停止を調べる（読み取りのみ）
"== WezTerm =="
$wz = "C:\Program Files\WezTerm"
if (Test-Path "$wz\wezterm-gui.exe") {
    "version: " + (Get-Item "$wz\wezterm-gui.exe").VersionInfo.FileVersion
    Get-Item "$wz\OpenConsole.exe", "$wz\conpty.dll" -ErrorAction SilentlyContinue |
        ForEach-Object { "{0,-16} {1:yyyy-MM-dd}" -f $_.Name, $_.LastWriteTime }
} else { "見つからない: $wz" }

"`n== 応答停止（WER） =="
# 送信されていないレポートは ReportQueue に残る
$werDirs = foreach ($root in "$env:ProgramData\Microsoft\Windows\WER", "$env:LOCALAPPDATA\Microsoft\Windows\WER") {
    "$root\ReportArchive"; "$root\ReportQueue"
}
$rows = Get-ChildItem $werDirs -Directory -ErrorAction SilentlyContinue |
    Where-Object Name -match 'AppHang.*wezterm' | ForEach-Object {
        $w = Get-Content (Join-Path $_.FullName "Report.wer") -Encoding Unicode -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Date      = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
            Type      = (($w | Where-Object { $_ -like "EventType=*" }) -replace "^EventType=")
            WaitingOn = (($w | Where-Object { $_ -like "Sig``[5``].Value=*" }) -replace "^.*?=")
            Sent      = $_.Parent.Name -eq "ReportArchive"
        }
    }
if ($rows) { ($rows | Sort-Object Date | Format-Table -AutoSize | Out-String).Trim() } else { "なし" }

"`n== 応答停止（イベントログ、90 日） =="
$ev = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1002; StartTime = (Get-Date).AddDays(-90) } -ErrorAction SilentlyContinue |
    Where-Object { $_.Properties[0].Value -like 'wezterm*' }
if ($ev) { $ev | ForEach-Object { "{0:yyyy-MM-dd HH:mm}  {1}" -f $_.TimeCreated, $_.Properties[9].Value } } else { "なし" }

"`n== プロセス =="
"wezterm-gui:           " + @(Get-Process wezterm-gui -ErrorAction SilentlyContinue).Count
"wezterm-mux-server:    " + @(Get-Process wezterm-mux-server -ErrorAction SilentlyContinue).Count
"OpenConsole (WezTerm): " + @(Get-CimInstance Win32_Process -Filter "Name='OpenConsole.exe'" | Where-Object ExecutablePath -like "*WezTerm*").Count

"`n== 環境 =="
"session: $env:SESSIONNAME"
Get-CimInstance Win32_VideoController | ForEach-Object { "gpu: $($_.Name) ($($_.DriverVersion))" }
Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
    ForEach-Object { "security: $($_.displayName)" }
"winget: " + $(if (Get-Command winget -ErrorAction SilentlyContinue) { "あり" } else { "なし" })