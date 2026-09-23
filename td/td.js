// Opens the tadoru picker in WezTerm: as a new tab when a WezTerm window is
// already running, otherwise in a new window. Enter starts a shell in the
// chosen folder. Run with wscript so no console shows.
// Usage: wscript td.js [mode] [root]   (mode: dirs, files, recent, favorites, browse;
//        root: a folder, or a favorite by name, with or without the colon; either
//        may be left out, in either order: "td work", "td browse work", "td browse")
var sh = new ActiveXObject("WScript.Shell");
var fso = new ActiveXObject("Scripting.FileSystemObject");

var args = WScript.Arguments;
var home = sh.ExpandEnvironmentStrings("%USERPROFILE%");
var mode = "dirs";
// Where a plain "td" starts. The folder is one PC's layout, so home stands
// in where it does not exist.
var root = home + "\\folder\\work";
if (!fso.FolderExists(root)) root = home;
// A word that names a mode is the mode. A folder that exists is where to
// start; any other word is a favorite's name, so the colon can be left off here.
var modes = { dirs: 1, files: 1, recent: 1, favorites: 1, browse: 1 };
for (var a = 0; a < args.length; a++) {
    var word = args(a);
    if (modes[word.toLowerCase()]) mode = word.toLowerCase();
    else if (word.charAt(0) === ":" || fso.FolderExists(word)) root = word;
    else root = ":" + word;
}
var wezDir = "C:\\Program Files\\WezTerm\\";
var tadoru = fso.GetParentFolderName(WScript.ScriptFullName) + "\\tadoru.exe";
// What Enter starts in the chosen folder: the name of an action, built in or
// from config\actions.json. Upper and lower case are not told apart.
//   "PowerShell here"  pwsh with the profile, from config\actions.json
//   "Open shell here"  built in; starts %ComSpec%, which is cmd.exe
// To be sure of cmd.exe whatever ComSpec says, add this to actions.json and
// name it here:  { "name": "cmd here", "program": "cmd.exe", "target": "directory" }
// An editor or anything else in the menu works the same way.
var onAccept = "PowerShell here";
// var onAccept = "Open shell here";
// A favorite's name is left to tadoru to look up; the tab itself starts at
// home, since WezTerm needs a folder that exists.
var cwd = root.charAt(0) === ":" ? home : root;
var tail = ' --cwd "' + cwd + '" -- "' + tadoru + '" pick --mode ' + mode +
    ' --root "' + root + '" --on-accept "' + onAccept + '" --after-action quit';

// The process IDs of the WezTerm windows running now.
function runningWindows() {
    var ids = {};
    var wmi = GetObject("winmgmts:\\\\.\\root\\cimv2");
    var found = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name = 'wezterm-gui.exe'");
    for (var e = new Enumerator(found); !e.atEnd(); e.moveNext()) ids[e.item().ProcessId] = true;
    return ids;
}

// WezTerm finds a running instance through a symlink it cannot create on
// Windows without Developer Mode, so the sockets are tried directly instead.
// Every window that ever ran leaves its socket behind, named after its
// process ID. Newest first, since a running window is almost always the last
// one started.
function sockets() {
    var dir = home + "\\.local\\share\\wezterm";
    var found = [];
    if (!fso.FolderExists(dir)) return found;
    for (var e = new Enumerator(fso.GetFolder(dir).Files); !e.atEnd(); e.moveNext()) {
        var m = /^gui-sock-(\d+)$/.exec(e.item().Name);
        if (m) found.push({ path: e.item().Path, pid: +m[1], at: +new Date(e.item().DateLastModified) });
    }
    found.sort(function (a, b) { return b.at - a.at; });
    return found;
}

// A note of each step, for when nothing seems to happen: %TEMP%\\td.log
var logPath = sh.ExpandEnvironmentStrings("%TEMP%") + "\\td.log";
function log(text) {
    try {
        var f = fso.OpenTextFile(logPath, 8, true);
        f.WriteLine(new Date().toLocaleTimeString() + "  " + text);
        f.Close();
    } catch (e) {}
}

var env = sh.Environment("Process");

// Brings the window of a wezterm-gui process to the front, restoring it when
// it is minimized, and says whether it has one. AppActivate alone reports a
// minimized window as none, and a tab opened there went into a new window
// instead. A wezterm-gui process can also outlive its last window, and a
// tab opened there is never seen, so the window is what is checked.
function activate(pid) {
    var script = sh.ExpandEnvironmentStrings("%TEMP%") + "\\td-activate.ps1";
    var f = fso.CreateTextFile(script, true);
    f.WriteLine("$p = Get-Process -Id " + pid + " -ErrorAction SilentlyContinue");
    f.WriteLine("if (-not $p -or $p.MainWindowHandle -eq 0) { exit 2 }");
    f.WriteLine("Add-Type -Namespace Td -Name Win -MemberDefinition @'");
    f.WriteLine('[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);');
    f.WriteLine('[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);');
    f.WriteLine('[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);');
    f.WriteLine("'@");
    f.WriteLine("$h = $p.MainWindowHandle");
    f.WriteLine("if ([Td.Win]::IsIconic($h)) { [Td.Win]::ShowWindow($h, 9) | Out-Null }");
    f.WriteLine("[Td.Win]::SetForegroundWindow($h) | Out-Null");
    f.WriteLine("exit 0");
    f.Close();
    var code = sh.Run('powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + script + '"', 0, true);
    return code === 0;
}

function spawnInto(socket) {
    if (!activate(socket.pid)) {
        log("gui-sock-" + socket.pid + ": process has no window");
        return false;
    }
    env("WEZTERM_UNIX_SOCKET") = socket.path;
    // Without --no-auto-start a socket that refuses the connection makes
    // wezterm start a hidden server of its own and wait on it, seconds each
    // time, and the server stays behind with a shell nobody can see.
    var code = sh.Run('"' + wezDir + 'wezterm.exe" cli --no-auto-start spawn' + tail, 0, true);
    log("cli spawn into gui-sock-" + socket.pid + " -> exit " + code);
    return code === 0;
}

log("start: mode=" + mode + " root=" + root);
var all = sockets();
log("sockets found: " + all.length);
// Only sockets of windows running now are tried, newest first. A socket
// left by a closed window can be answered by a headless mux server that a
// cli call without --no-auto-start once started: the tab then opens where
// nothing can be seen, and tadoru sits there until it is killed.
var alive = runningWindows();
for (var i = 0; i < all.length; i++) {
    if (alive[all[i].pid] && spawnInto(all[i])) WScript.Quit(0);
}
env.Remove("WEZTERM_UNIX_SOCKET");
log("no window answered; starting a new one");
var started = sh.Run('"' + wezDir + 'wezterm-gui.exe" start' + tail, 1, false);
log("wezterm-gui start -> " + started);
// The new window does not always come to the front on its own, so once it
// is there, which is a new wezterm-gui process, it is brought there.
for (var wait = 0; wait < 50; wait++) {
    WScript.Sleep(200);
    var now = runningWindows();
    for (var pid in now) {
        if (!alive[pid] && activate(+pid)) {
            log("new window " + pid + " brought to the front");
            WScript.Quit(0);
        }
    }
}
log("new window not found to bring to the front");
