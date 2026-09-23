# Creates td.lnk beside td.js, so "td" in the Run dialog (Win+R) starts the
# launcher once this folder is on PATH. The shortcut runs wscript without a
# console window. Run this again after moving the folder.
$here = $PSScriptRoot
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $here 'td.lnk'))
$shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$shortcut.Arguments = '//nologo //E:JScript "' + (Join-Path $here 'td.js') + '"'
$shortcut.WorkingDirectory = $HOME
$shortcut.Save()
"created " + (Join-Path $here 'td.lnk')

$onPath = ($env:PATH -split ';') -contains $here
if (-not $onPath) {
    "this folder is not on PATH yet; add it so Win+R finds td:"
    "  [Environment]::SetEnvironmentVariable('PATH', [Environment]::GetEnvironmentVariable('PATH', 'User') + ';$here', 'User')"
}
