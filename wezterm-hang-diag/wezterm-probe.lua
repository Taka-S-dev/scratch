-- Lua API の所要時間を測る。4 ペイン開いて測ったあと終了し、結果を ~/wezterm-probe-result.txt に追記する。
-- wezterm-gui --config-file wezterm-probe.lua start --always-new-process
local wezterm = require 'wezterm'
local mux = wezterm.mux
local OUT = wezterm.home_dir .. '/wezterm-probe-result.txt'
local function log(s) local f = io.open(OUT, 'a'); f:write(s .. '\n'); f:close() end

local config = wezterm.config_builder()
config.default_prog = { 'powershell', '-NoProfile', '-NoLogo', '-Command', 'Start-Sleep -Seconds 30' }
config.window_close_confirmation = 'NeverPrompt'

local function timeit(label, n, f)
  local t0 = os.clock()
  for _ = 1, n do f() end
  log(string.format('%-40s per_call=%.3f ms', label, (os.clock() - t0) * 1000 / n))
end

wezterm.on('gui-startup', function(cmd)
  local _, pane = mux.spawn_window(cmd or {})
  local p2 = pane:split { direction = 'Right' }
  pane:split { direction = 'Bottom' }
  p2:split { direction = 'Bottom' }
end)

wezterm.on('update-right-status', function(window, pane)
  local tab = window:active_tab()
  if wezterm.GLOBAL.probe_done or not tab or #tab:panes() < 4 then return end
  wezterm.GLOBAL.probe_done = true
  log('== ' .. wezterm.version .. '  ' .. os.date('%Y-%m-%d %H:%M'))
  timeit('pane:get_foreground_process_name()', 50, function() pane:get_foreground_process_name() end)
  timeit('pane:get_current_working_dir()', 50, function() pane:get_current_working_dir() end)
  timeit('tab:panes_with_info() [4 panes]', 50, function() tab:panes_with_info() end)
  local infos = tab:panes_with_info()
  timeit('PaneInformation.foreground_process_name', 50, function() local _ = infos[1].foreground_process_name end)
  window:perform_action(wezterm.action.QuitApplication, pane)
end)

return config
