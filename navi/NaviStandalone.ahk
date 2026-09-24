#Requires AutoHotkey v2.0
#SingleInstance Force
; Navi を My-AHK-Scripts なしで試すためのランチャー
; Ctrl+Alt+F で Navi を開く（もう一度押すと最小化）。起動した直後にも一度開く
; 設定（Navi.ini）は ui\navi\ に作られる

#Include ui\navi\Navi.ahk

^!f:: Navi.Show()

Navi.Show()
