; ==============================================================================
; Module:       ExplorerSwitch.ahk
; Description:  開いている Windows Explorer をパスで検索して切り替える
;
; Usage Example (Main.ahk):
;   #Include "ui\ExplorerSwitch.ahk"
;   ExplorerSwitch.Init()
;   #HotIf GetKeyState(MOD_KEY, "P")
;   e:: ExplorerSwitch.Toggle()
;   #HotIf
; ==============================================================================
#Requires AutoHotkey v2.0

class ExplorerSwitch {
    static IniPath := A_ScriptDir "\ui\ExplorerSwitch.ini"
    static GuiObj := 0
    static Items := []
    static FilteredItems := []
    static PinnedHwnds := Map()
    ; hwnd -> 1..9。ピン留め中は番号を固定し、再起動時にはリセットする。
    static FavoriteNumbers := Map()
    static LayoutSlots := Map()
    static ImageListId := 0
    static IconIndexes := Map()
    static _hotifFn := ""
    static _refreshTimerFn := ""
    static _cacheTimerFn := ""
    static _focusWatchTimerFn := ""
    static _notifyFn := ""
    static _focusWatchBorn := 0
    static _focusEverActive := false
    static _suspendAutoCloseUntil := 0
    static _ignoreFocusLossUntilReactivated := false
    static _initialized := false
    static _lastMouseShowTick := 0
    static _refreshBusy := false
    static _lastUseTick := 0
    static _lastTypeTick := 0
    static _resultsHwnd := 0
    static _notifyHooked := false
    ; hwnd -> {title, path, displayName, isFileSystem}。COM呼び出しを省くための一時キャッシュ。
    static _pathCache := Map()
    static _fullQueryCountdown := 0
    ; 表示中の行並びを固定するための hwnd -> 表示順。
    static _orderLock := Map()
    static _orderLockNext := 0

    ; いずれも初回の既定値。GUIで変更後はINIの保存値を使用する。
    static CloseOnFocusLoss := true
    ; trueならExplorer切替後もSwitcherを表示したままにする。
    static KeepOpenAfterActivate := false
    ; 通常のAlt+Tab対象アプリも一覧へ加える。
    static IncludeApps := false
    static REFRESH_INTERVAL := 1000
    static CACHE_REFRESH_INTERVAL := 3000
    ; 最後にSwitcherを使ってからこの時間が経つと裏の一覧更新を止める。
    static CACHE_IDLE_TIMEOUT := 60000
    ; この回数に1回はパスキャッシュを使わずCOMから取り直す。
    static FULL_QUERY_EVERY := 10
    ; 入力直後はこの時間だけ定期更新を見送り、打鍵の引っかかりを避ける。
    static TYPING_QUIET_PERIOD := 300
    static SHOW_REFRESH_DELAY := -40
    static FOCUS_WATCH_INTERVAL := 100
    static ACTIVATE_DELAY := -60
    static REFOCUS_DELAY := -150
    static EM_SETCUEBANNER := 0x1501
    static LVM_ENSUREVISIBLE := 0x1013
    static LVM_GETTOPINDEX := 0x1027
    static LVM_GETCOUNTPERPAGE := 0x1028
    static LVM_SUBITEMHITTEST := 0x1039
    static LVM_SETCOLUMNORDERARRAY := 0x103A
    static WM_NOTIFY := 0x004E
    static NM_CUSTOMDRAW := -12
    static CDDS_PREPAINT := 0x00000001
    static CDDS_ITEMPREPAINT := 0x00010001
    static CDRF_NOTIFYITEMDRAW := 0x00000020
    static MINIMIZED_TEXT_COLOR := 0x888888

    static Init() {
        if this._initialized
            return

        this.CloseOnFocusLoss := this._ReadSetting("CloseOnFocusLoss", this.CloseOnFocusLoss)
        this.KeepOpenAfterActivate := this._ReadSetting("KeepOpenAfterActivate",
            this.KeepOpenAfterActivate)
        this.IncludeApps := this._ReadSetting("IncludeApps", this.IncludeApps)

        this._hotifFn := (*) => this.GuiObj
            && this._GuiExists()
            && WinActive("ahk_id " . this.GuiObj.Hwnd)
        this._refreshTimerFn := () => this._RefreshWhileVisible()
        this._cacheTimerFn := () => this._RefreshCacheWhileHidden()
        this._focusWatchTimerFn := () => this._FocusWatchTick()
        ; WM_NOTIFYはプロセス内の全GUIから飛んでくるので、常時フックすると
        ; Switcherを開いていない間もMain.ahkの他モジュールに負担がかかる。
        ; 実際に描画が必要な「表示中」だけ登録する。
        this._notifyFn := (wParam, lParam, msg, hwnd) => this._OnNotify(wParam, lParam, msg, hwnd)

        HotIf(this._hotifFn)
        Hotkey("Escape", (*) => this.HandleEscape(), "On")
        Hotkey("Enter", (*) => this.ActivateSelected(), "On")
        Hotkey("+Enter", (*) => this.ToggleSelectedVisibility(), "On")
        Hotkey("F5", (*) => this.ForceRefresh(), "On")
        Hotkey("^f", (*) => this.FocusSearch(), "On")
        Hotkey("^c", (*) => this.CopySelectedPath(), "On")
        Hotkey("^p", (*) => this.TogglePin(), "On")
        Hotkey("^+p", (*) => this.ClearAllFavorites(), "On")
        Hotkey("^m", (*) => this.MinimizeAll(), "On")
        Hotkey("^g", (*) => this.ArrangeOnCurrentMonitors(), "On")
        Hotkey("^0", (*) => this.AssignSelectedLayoutSlot(0), "On")
        Hotkey("^1", (*) => this.AssignSelectedLayoutSlot(1), "On")
        Hotkey("^2", (*) => this.AssignSelectedLayoutSlot(2), "On")
        Hotkey("^3", (*) => this.AssignSelectedLayoutSlot(3), "On")
        Hotkey("^4", (*) => this.AssignSelectedLayoutSlot(4), "On")
        Hotkey("^Delete", (*) => this.CloseDuplicates(), "On")
        Hotkey("Up", (*) => this._MoveSelection(-1), "On")
        Hotkey("Down", (*) => this._MoveSelection(1), "On")
        Loop 9 {
            favoriteNumber := A_Index
            favoriteHandler := ObjBindMethod(this, "HandleFavoriteDigit", favoriteNumber)
            assignFavoriteHandler := ObjBindMethod(this,
                "AssignSelectedFavoriteNumber", favoriteNumber)
            ; $ を付け、検索欄へ送り直した数字で自身を再発火させない。
            Hotkey("$" . favoriteNumber, favoriteHandler, "On")
            Hotkey("$Numpad" . favoriteNumber, favoriteHandler, "On")
            Hotkey("^+" . favoriteNumber, assignFavoriteHandler, "On")
            Hotkey("^+Numpad" . favoriteNumber, assignFavoriteHandler, "On")
        }
        HotIf()

        ; GUIを初めて開く前に一覧を用意しておく。以後の定期更新は実際にSwitcherを
        ; 使った前後だけ回す（常時のCOM列挙はネットワークパスで待たされ得るため）。
        this._lastUseTick := A_TickCount
        SetTimer(this._cacheTimerFn, -50)
        this._initialized := true
    }

    static _ReadSetting(key, defaultValue) {
        try
            return IniRead(this.IniPath, "Settings", key, defaultValue ? "1" : "0") == "1"
        catch
            return defaultValue
    }

    static _WriteSetting(key, value) {
        try IniWrite(value ? "1" : "0", this.IniPath, "Settings", key)
    }

    static Toggle() {
        if (this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd)) {
            if WinActive("ahk_id " . this.GuiObj.Hwnd) {
                this.Hide()
                return
            }
        }
        this.Show()
    }

    static ShowFromMouse() {
        ; マウスボタンのチャタリングや連続入力を捨て、最初の1回だけを
        ; 表示／非表示トグルとして扱う。
        if (this._lastMouseShowTick
            && A_TickCount - this._lastMouseShowTick < 250)
            return
        this._lastMouseShowTick := A_TickCount

        if (this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd)) {
            this.Hide()
            return
        }
        this.Show(true)
    }

    static Show(showNearMouse := false) {
        if !this._initialized
            this.Init()
        if !this._GuiExists()
            this._CreateGui()
        this._lastUseTick := A_TickCount
        this._StopCacheTimer()
        this._StartNotifyHook()
        ; 開くたびに最新のZ順で並びを取り直し、以後は閉じるまで固定する。
        this._orderLock.Clear()
        this._orderLockNext := 0

        ; 前回の絞り込みを持ち越して空一覧に見えることを防ぐ。
        this.GuiObj["Search"].Value := ""
        ; キャッシュから先に描画して、COM列挙を待たずにウィンドウを表示する。
        this.ApplyFilter("")
        if showNearMouse {
            ; サイズ確定後に、ポインターがあるモニターの作業領域内へ配置する。
            this.GuiObj.Show("AutoSize Hide")
            rect := Buffer(16, 0)
            DllCall("user32\GetWindowRect", "ptr", this.GuiObj.Hwnd, "ptr", rect)
            guiWidth := NumGet(rect, 8, "int") - NumGet(rect, 0, "int")
            guiHeight := NumGet(rect, 12, "int") - NumGet(rect, 4, "int")
            position := this._GetMousePopupPosition(guiWidth, guiHeight)
            this.GuiObj.Show("AutoSize x" . position.x . " y" . position.y)
        } else
            this.GuiObj.Show("AutoSize")
        WinActivate("ahk_id " . this.GuiObj.Hwnd)
        this.GuiObj["Search"].Focus()
        this._StartRefreshTimer()
        this._StartFocusWatch()
        ; GUIの初回描画後に最新状態へ追従する。
        SetTimer(() => this.Refresh(), this.SHOW_REFRESH_DELAY)
    }

    static _GetMousePopupPosition(guiWidth, guiHeight) {
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mouseX, &mouseY)
        point := (mouseY << 32) | (mouseX & 0xFFFFFFFF)
        monitor := DllCall("user32\MonitorFromPoint", "int64", point,
            "uint", 2, "ptr")

        mi := Buffer(40, 0)
        NumPut("uint", 40, mi, 0)
        if (!monitor || !DllCall("user32\GetMonitorInfoW", "ptr", monitor, "ptr", mi))
            return {x: mouseX + 18, y: mouseY + 18}

        left := NumGet(mi, 20, "int")
        top := NumGet(mi, 24, "int")
        right := NumGet(mi, 28, "int")
        bottom := NumGet(mi, 32, "int")
        gap := 18

        ; 基本は右下。収まらなければポインターの反対側へ開く。
        x := mouseX + gap
        if (x + guiWidth > right)
            x := mouseX - guiWidth - gap
        y := mouseY + gap
        if (y + guiHeight > bottom)
            y := mouseY - guiHeight - gap

        return {
            x: Max(left, Min(x, right - guiWidth)),
            y: Max(top, Min(y, bottom - guiHeight))
        }
    }

    static Hide() {
        this._StopRefreshTimer()
        this._StopFocusWatch()
        this._StopNotifyHook()
        if this._GuiExists()
            this.GuiObj.Hide()
        ; 続けて開き直される可能性が高い間だけ、裏で一覧を温め直す。
        this._lastUseTick := A_TickCount
        this._StartCacheTimer()
    }

    static _GuiExists() {
        return this.GuiObj && this.GuiObj.Hwnd
            && DllCall("user32\IsWindow", "ptr", this.GuiObj.Hwnd)
    }

    static Refresh() {
        ; 列挙中に定期タイマーやホットキーが割り込んで多重実行されると、
        ; Itemsと実際の行が食い違い、行番号での操作が別ウィンドウへ届き得る。
        if (!this._GuiExists() || this._refreshBusy)
            return

        this._refreshBusy := true
        try
            this._RefreshCore()
        finally
            this._refreshBusy := false
    }

    ; F5用。キャッシュを無視して必ずCOMから取り直す。
    static ForceRefresh() {
        this._fullQueryCountdown := 0
        this.Refresh()
    }

    static _RefreshCore() {
        selectedHwnd := this._GetSelectedHwnd()
        lv := this.GuiObj["Results"]
        topIndex := SendMessage(this.LVM_GETTOPINDEX, 0, 0, lv)
        result := this._EnumerateVisibleItems()
        if !result.ok {
            this._SetStatus("Explorer一覧を取得できませんでした。F5で再試行できます")
            return
        }
        newItems := result.items
        query := this.GuiObj["Search"].Value
        expectedRowCount := this._CountMatches(newItems, query)

        ; 定期更新ごとの全行再作成はスクロール位置を先頭へ戻してしまう。
        ; 表示内容に実質的な変更がなく、GUIの実際の行数も正しい場合だけ触れない。
        ; GUIが作り直された場合はItemsが同じでも空なので必ず再構築する。
        if (this._ItemsEquivalent(this.Items, newItems) && lv.GetCount() == expectedRowCount)
            return

        this.Items := newItems
        this.ApplyFilter(query, selectedHwnd, topIndex)
    }

    static ApplyFilter(query, preferredHwnd := 0, preferredTopIndex := -1) {
        if !this._GuiExists()
            return

        query := Trim(query)
        tokens := this._TokenizeQuery(query)
        filtered := []
        for item in this.Items {
            if this._ItemMatchesTokens(item, tokens)
                filtered.Push(item)
        }
        this.FilteredItems := filtered

        lv := this.GuiObj["Results"]
        lv.Opt("-Redraw")
        lv.Delete()
        selectRow := 0
        for row, item in filtered {
            duplicateMark := item.duplicateCount > 1 ? "  [x" . item.duplicateCount . "]" : ""
            favoriteNumber := this._GetFavoriteNumber(item.hwnd)
            pinMark := favoriteNumber ? "[" . favoriteNumber . "] " : ""
            minimizeText := item.isMinimized ? "🗗" : "🗕"
            isExplorer := item.kind == "explorer"
            detail := isExplorer ? item.path : item.title
            iconIndex := this._GetItemIconIndex(item)
            rowOptions := iconIndex > 0 ? "Icon" . iconIndex : ""
            lv.Add(rowOptions, pinMark . item.displayName . duplicateMark,
                minimizeText, isExplorer ? this._GetLayoutSlotIcon(item.hwnd) : "",
                detail)
            if (preferredHwnd && item.hwnd == preferredHwnd)
                selectRow := row
        }
        lv.Opt("+Redraw")

        if (filtered.Length > 0) {
            if (selectRow == 0)
                selectRow := 1
            lv.Modify(selectRow, "Select Focus Vis")
            if (preferredTopIndex >= 0)
                this._RestoreListScroll(lv, preferredTopIndex)
        }
        this._UpdateStatus()
    }

    static ActivateSelected() {
        if this._IsImeComposing() {
            ; Enterホットキーが元のキー入力を消費するため、変換中は検索欄へ
            ; Enterを送り直してIME確定だけを行う。次のEnterで切り替える。
            Send("{Enter}")
            return
        }

        this._ActivateItem(this._GetSelectedItem())
    }

    static _ActivateItem(item) {
        if !item
            return
        if !this._IsItemWindowValid(item) {
            this.Refresh()
            return
        }

        hwnd := item.hwnd
        if this.KeepOpenAfterActivate
            SetTimer(() => this._ActivateKeepingSwitcher(hwnd), this.ACTIVATE_DELAY)
        else {
            this.Hide()
            SetTimer(() => this._ActivateHwnd(hwnd), this.ACTIVATE_DELAY)
        }
    }

    static CopySelectedPath() {
        item := this._GetSelectedItem()
        if !item
            return
        if (item.kind != "explorer" || !item.isFileSystem) {
            this._SetStatus("この行にはコピーできるフォルダーパスがありません")
            return
        }
        A_Clipboard := item.path
        this._SetStatus("コピーしました: " . item.path)
    }

    static FocusSearch() {
        if !this._GuiExists()
            return
        try this.GuiObj["Search"].Focus()
    }

    static HandleEscape() {
        if !this._GuiExists()
            return

        search := this.GuiObj["Search"]
        if (search.Value != "") {
            search.Value := ""
            this.ApplyFilter("")
            this.FocusSearch()
            return
        }
        this.Hide()
    }

    static SetCloseOnFocusLoss(enabled) {
        this.CloseOnFocusLoss := enabled ? true : false
        this._WriteSetting("CloseOnFocusLoss", this.CloseOnFocusLoss)

        if !(this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd))
            return
        if this.CloseOnFocusLoss
            this._StartFocusWatch()
        else
            this._StopFocusWatch()
        this.FocusSearch()
    }

    static SetKeepOpenAfterActivate(enabled) {
        this.KeepOpenAfterActivate := enabled ? true : false
        this._WriteSetting("KeepOpenAfterActivate", this.KeepOpenAfterActivate)
        this.FocusSearch()
    }

    static SetIncludeApps(enabled) {
        this.IncludeApps := enabled ? true : false
        this._WriteSetting("IncludeApps", this.IncludeApps)
        this.Refresh()
        this.FocusSearch()
    }

    static TogglePin() {
        item := this._GetSelectedItem()
        if !item
            return

        if this.PinnedHwnds.Has(item.hwnd) {
            this.PinnedHwnds.Delete(item.hwnd)
            if this.FavoriteNumbers.Has(item.hwnd)
                this.FavoriteNumbers.Delete(item.hwnd)
            message := "ピン留めを解除しました: " . item.displayName
        } else {
            favoriteNumber := this._FindAvailableFavoriteNumber()
            if !favoriteNumber {
                this._SetStatus("お気に入りは9件までです")
                return
            }
            this.PinnedHwnds[item.hwnd] := true
            this.FavoriteNumbers[item.hwnd] := favoriteNumber
            message := "お気に入り " . favoriteNumber . " に登録しました: " . item.displayName
        }

        ; ピン状態による再ソート後も、操作したウィンドウの選択を維持する。
        selectedHwnd := item.hwnd
        this.Refresh()
        this._SetStatus(message)
        this._SelectHwnd(selectedHwnd)
    }

    ; 検索欄が空で番号が登録済みの場合だけショートカットとして扱う。
    ; それ以外は数字を検索欄へ渡すため、数字を含む名前やパスも検索できる。
    static HandleFavoriteDigit(favoriteNumber, *) {
        if !this._GuiExists()
            return
        search := this.GuiObj["Search"]
        if (search.Value != "" || this._IsImeComposing()) {
            this._TypeSearchDigit(favoriteNumber)
            return
        }

        hwnd := this._GetFavoriteHwnd(favoriteNumber)
        if !hwnd {
            this._TypeSearchDigit(favoriteNumber)
            return
        }

        item := this._FindItemByHwnd(hwnd, this.Items)
        if (!item || !this._IsItemWindowValid(item)) {
            this.PinnedHwnds.Delete(hwnd)
            this.FavoriteNumbers.Delete(hwnd)
            this.Refresh()
            this._SetStatus("お気に入り " . favoriteNumber . " のウィンドウは閉じられています")
            return
        }
        this._ActivateItem(item)
    }

    static _TypeSearchDigit(favoriteNumber) {
        this.FocusSearch()
        SendText(favoriteNumber . "")
    }

    static _FindAvailableFavoriteNumber() {
        Loop 9 {
            if !this._GetFavoriteHwnd(A_Index)
                return A_Index
        }
        return 0
    }

    static _GetFavoriteNumber(hwnd) {
        return this.FavoriteNumbers.Has(hwnd) ? this.FavoriteNumbers[hwnd] : 0
    }

    static _GetFavoriteHwnd(favoriteNumber) {
        for hwnd, assignedNumber in this.FavoriteNumbers {
            if (assignedNumber == favoriteNumber)
                return hwnd
        }
        return 0
    }

    static ClearAllFavorites() {
        count := this.PinnedHwnds.Count
        if (count == 0) {
            this._SetStatus("解除するお気に入りはありません")
            return
        }

        selectedHwnd := this._GetSelectedHwnd()
        lv := this.GuiObj["Results"]
        topIndex := SendMessage(this.LVM_GETTOPINDEX, 0, 0, lv)
        this.PinnedHwnds.Clear()
        this.FavoriteNumbers.Clear()
        for item in this.Items
            item.isPinned := false
        this.ApplyFilter(this.GuiObj["Search"].Value, selectedHwnd, topIndex)
        this._SetStatus(count . "件のお気に入りを解除しました")
        this.FocusSearch()
    }

    ; 選択中のお気に入りへ任意番号を割り当てる。使用中なら両者を入れ替え、
    ; どちらかの番号が突然消えないようにする。
    static AssignSelectedFavoriteNumber(favoriteNumber, *) {
        item := this._GetSelectedItem()
        if !item
            return
        if !this.PinnedHwnds.Has(item.hwnd) {
            this._SetStatus("先にCtrl+Pでお気に入りへ登録してください")
            return
        }

        oldNumber := this._GetFavoriteNumber(item.hwnd)
        if (oldNumber == favoriteNumber) {
            this._SetStatus("お気に入り番号は既に " . favoriteNumber . " です")
            return
        }

        swapHwnd := this._GetFavoriteHwnd(favoriteNumber)
        this.FavoriteNumbers[item.hwnd] := favoriteNumber
        if swapHwnd
            this.FavoriteNumbers[swapHwnd] := oldNumber

        selectedHwnd := item.hwnd
        lv := this.GuiObj["Results"]
        topIndex := SendMessage(this.LVM_GETTOPINDEX, 0, 0, lv)
        this.ApplyFilter(this.GuiObj["Search"].Value, selectedHwnd, topIndex)
        message := swapHwnd
            ? "お気に入り " . oldNumber . " と " . favoriteNumber . " を入れ替えました"
            : "お気に入り番号を " . favoriteNumber . " に変更しました"
        this._SetStatus(message)
        this.FocusSearch()
    }

    static MinimizeAll() {
        if !this._GuiExists()
            return
        ; フィルター表示だけでなく、実行時点で列挙できる全Explorerを対象にする。
        switcherHwnd := this.GuiObj.Hwnd
        ; WinMinimizeが発生させる一時的なフォーカス移動を外側クリックと誤認しない。
        this._suspendAutoCloseUntil := A_TickCount + 600
        result := this._EnumerateExplorerWindows()
        if !result.ok {
            this._SetStatus("Explorer一覧を取得できないため最小化を中止しました")
            return
        }
        currentItems := result.items
        minimizedCount := 0
        for item in currentItems {
            if !this._IsExplorerWindow(item.hwnd)
                continue
            try {
                if (WinGetMinMax("ahk_id " . item.hwnd) != -1)
                    WinMinimize("ahk_id " . item.hwnd)
                item.isMinimized := true
                minimizedCount += 1
            }
        }

        selectedHwnd := this._GetSelectedHwnd()
        if this.IncludeApps {
            for existingItem in this.Items {
                if (existingItem.kind == "app"
                    && DllCall("user32\IsWindow", "ptr", existingItem.hwnd))
                    currentItems.Push(existingItem)
            }
            this._SortItems(currentItems)
        }
        this.Items := currentItems
        this.ApplyFilter(this.GuiObj["Search"].Value, selectedHwnd)
        this._SetStatus(minimizedCount . "個のExplorerを最小化状態にしました")

        ; WinMinimize後にOSが別ウィンドウへフォーカスを渡す場合があるため、
        ; 直後と最小化アニメーション完了後の2段階でSwitcherへ戻す。
        this._RefocusSwitcherSoon(switcherHwnd)
    }

    static ToggleRowVisibility(row) {
        if (row < 1 || row > this.FilteredItems.Length)
            return
        item := this.FilteredItems[row]
        if !this._IsItemWindowValid(item) {
            this._SetStatus("対象のウィンドウは既に閉じられています")
            this.Refresh()
            return
        }

        switcherHwnd := this.GuiObj.Hwnd
        if (WinGetMinMax("ahk_id " . item.hwnd) == -1) {
            this._suspendAutoCloseUntil := A_TickCount + 600
            try WinRestore("ahk_id " . item.hwnd)
            item.isMinimized := false
            this.GuiObj["Results"].Modify(row, "Col2", "🗕")
            this._SetStatus("「" . item.displayName . "」を復元しました")
            this._RefocusSwitcherSoon(switcherHwnd)
            return
        }

        this._suspendAutoCloseUntil := A_TickCount + 600
        try WinMinimize("ahk_id " . item.hwnd)
        item.isMinimized := true
        this.GuiObj["Results"].Modify(row, "Col2", "🗗")
        this._SetStatus("「" . item.displayName . "」を最小化しました")
        this._RefocusSwitcherSoon(switcherHwnd)
    }

    static ToggleSelectedVisibility() {
        if this._IsImeComposing() {
            ; 日本語変換中はウィンドウ操作にせず、まず変換を確定する。
            Send("{Enter}")
            return
        }
        if !this._GuiExists()
            return
        row := this.GuiObj["Results"].GetNext()
        if (row >= 1 && row <= this.FilteredItems.Length)
            this.ToggleRowVisibility(row)
    }

    static AssignSelectedLayoutSlot(slot) {
        if !this._GuiExists()
            return
        row := this.GuiObj["Results"].GetNext()
        if (row < 1 || row > this.FilteredItems.Length)
            return
        if (this.FilteredItems[row].kind != "explorer") {
            this._SetStatus("配置指定はExplorerだけが対象です")
            return
        }
        this.AssignRowLayoutSlot(row, slot)
    }

    static ShowLayoutSlotMenu(row) {
        if (row < 1 || row > this.FilteredItems.Length)
            return
        if (this.FilteredItems[row].kind != "explorer") {
            this._SetStatus("配置指定はExplorerだけが対象です")
            this.FocusSearch()
            return
        }
        ; メニュー表示中もタイマーは動くため、選択が確定する頃には一覧が
        ; 作り直されて行番号が別のウィンドウを指している場合がある。
        ; 行ではなくHWNDを捕まえておく。
        hwnd := this.FilteredItems[row].hwnd
        current := this.LayoutSlots.Has(hwnd) ? this.LayoutSlots[hwnd] : 0

        slotMenu := Menu()
        slotMenu.Add("指定なし  (Ctrl+0)", (*) => this.AssignHwndLayoutSlot(hwnd, 0))
        slotMenu.Add()
        slotMenu.Add("◤  左上  (Ctrl+1)", (*) => this.AssignHwndLayoutSlot(hwnd, 1))
        slotMenu.Add("◥  右上  (Ctrl+2)", (*) => this.AssignHwndLayoutSlot(hwnd, 2))
        slotMenu.Add("◣  左下  (Ctrl+3)", (*) => this.AssignHwndLayoutSlot(hwnd, 3))
        slotMenu.Add("◢  右下  (Ctrl+4)", (*) => this.AssignHwndLayoutSlot(hwnd, 4))

        labels := ["指定なし  (Ctrl+0)", "◤  左上  (Ctrl+1)",
            "◥  右上  (Ctrl+2)", "◣  左下  (Ctrl+3)", "◢  右下  (Ctrl+4)"]
        slotMenu.Check(labels[current + 1])

        ; ポップアップメニューを外側クリックと誤認してSwitcherを閉じない。
        this._suspendAutoCloseUntil := A_TickCount + 60000
        ; メニューが開いている間は一覧を作り直さない。
        this._StopRefreshTimer()
        slotMenu.Show()
        this._StartRefreshTimer()
        this._suspendAutoCloseUntil := A_TickCount + 200
        this.FocusSearch()
    }

    static AssignRowLayoutSlot(row, slot) {
        if (row < 1 || row > this.FilteredItems.Length)
            return
        this.AssignHwndLayoutSlot(this.FilteredItems[row].hwnd, slot)
    }

    static AssignHwndLayoutSlot(hwnd, slot) {
        if (!hwnd || slot < 0 || slot > 4)
            return
        item := this._FindItemByHwnd(hwnd)
        if (!item || item.kind != "explorer")
            return
        oldSlot := this.LayoutSlots.Has(hwnd) ? this.LayoutSlots[hwnd] : 0
        if (slot == oldSlot) {
            this.FocusSearch()
            return
        }

        targetMonitor := DllCall("user32\MonitorFromWindow", "ptr", hwnd,
            "uint", 2, "ptr")
        swapHwnd := 0
        if (slot > 0) {
            for otherHwnd, otherSlot in this.LayoutSlots {
                if (otherHwnd == hwnd || otherSlot != slot || !WinExist("ahk_id " . otherHwnd))
                    continue
                otherMonitor := DllCall("user32\MonitorFromWindow", "ptr", otherHwnd,
                    "uint", 2, "ptr")
                if (otherMonitor == targetMonitor) {
                    swapHwnd := otherHwnd
                    break
                }
            }
        }

        if this.LayoutSlots.Has(hwnd)
            this.LayoutSlots.Delete(hwnd)
        if swapHwnd {
            if (oldSlot > 0)
                this.LayoutSlots[swapHwnd] := oldSlot
            else
                this.LayoutSlots.Delete(swapHwnd)
        }
        if (slot > 0)
            this.LayoutSlots[hwnd] := slot

        selectedHwnd := hwnd
        this.ApplyFilter(this.GuiObj["Search"].Value, selectedHwnd)
        message := slot > 0
            ? "「" . item.displayName . "」を配置 " . this._GetLayoutSlotIcon(hwnd) . " に指定しました"
            : "「" . item.displayName . "」の配置指定を解除しました"
        this._SetStatus(message)
        this.FocusSearch()
    }

    static _FindItemByHwnd(hwnd, items := 0) {
        if !items
            items := this.FilteredItems
        for item in items {
            if (item.hwnd == hwnd)
                return item
        }
        return 0
    }

    static _GetLayoutSlotIcon(hwnd) {
        static icons := ["", "◤", "◥", "◣", "◢"]
        slot := this.LayoutSlots.Has(hwnd) ? this.LayoutSlots[hwnd] : 0
        return slot >= 0 && slot <= 4 ? icons[slot + 1] : ""
    }

    static _GetItemIconIndex(item) {
        if !this.ImageListId
            return 0
        key := item.kind == "explorer" ? "explorer" : "app|" . StrLower(item.path)
        if this.IconIndexes.Has(key)
            return this.IconIndexes[key]

        iconFile := item.kind == "explorer" ? A_WinDir . "\explorer.exe" : item.path
        iconIndex := 0
        if (iconFile != "" && FileExist(iconFile))
            try iconIndex := IL_Add(this.ImageListId, iconFile)
        if (iconIndex == 0) {
            fallbackKey := "fallback"
            if this.IconIndexes.Has(fallbackKey)
                iconIndex := this.IconIndexes[fallbackKey]
            else {
                try iconIndex := IL_Add(this.ImageListId, A_WinDir . "\System32\shell32.dll", 1)
                this.IconIndexes[fallbackKey] := iconIndex
            }
        }
        this.IconIndexes[key] := iconIndex
        return iconIndex
    }

    static _SetListColumnOrder(lv) {
        ; 内部列は「名前・最小化・配置・詳細」のまま、表示だけ
        ; 「最小化・配置・名前・詳細」へ並べ替える。
        order := Buffer(16, 0)
        NumPut("int", 1, order, 0)
        NumPut("int", 2, order, 4)
        NumPut("int", 0, order, 8)
        NumPut("int", 3, order, 12)
        return DllCall("user32\SendMessageW", "ptr", lv.Hwnd,
            "uint", this.LVM_SETCOLUMNORDERARRAY,
            "ptr", 4, "ptr", order, "ptr") != 0
    }

    static ClearAllLayoutSlots() {
        if (this.LayoutSlots.Count == 0) {
            this._SetStatus("解除する配置指定はありません")
            this.FocusSearch()
            return
        }

        selectedHwnd := this._GetSelectedHwnd()
        lv := this.GuiObj["Results"]
        topIndex := SendMessage(this.LVM_GETTOPINDEX, 0, 0, lv)
        this.LayoutSlots.Clear()
        this.ApplyFilter(this.GuiObj["Search"].Value, selectedHwnd, topIndex)
        this._SetStatus("すべての配置指定を解除しました")
        this.FocusSearch()
    }

    static ArrangeOnCurrentMonitors() {
        if !this._GuiExists()
            return
        switcherHwnd := this.GuiObj.Hwnd
        this._suspendAutoCloseUntil := A_TickCount + 800
        result := this._EnumerateExplorerWindows()
        if !result.ok {
            this._SetStatus("Explorer一覧を取得できないため整列を中止しました")
            return
        }

        currentItems := result.items
        for item in currentItems
            item.layoutSlot := this.LayoutSlots.Has(item.hwnd) ? this.LayoutSlots[item.hwnd] : 0

        targetMonitor := ExplorerLayout.GetMonitorAtCursor()
        arrangedCount := ExplorerLayout.ArrangeOnCurrentMonitors(currentItems,
            (result) => this._OnArrangeVerified(result), targetMonitor)
        if (arrangedCount > 0) {
            message := arrangedCount . "個の表示中Explorerをマウス画面へ2×2配置しました"
            if (ExplorerLayout.LastSkippedCount > 0)
                message .= "（残り" . ExplorerLayout.LastSkippedCount . "個は対象外）"
            this._SetStatus(message)
        } else
            this._SetStatus("整列対象の表示中Explorerはありません")

        this._RefocusSwitcherSoon(switcherHwnd)
    }

    ; 整列の反映確認が終わった時点で呼ばれる。問題があった時だけ上書きする。
    static _OnArrangeVerified(result) {
        if !this._GuiExists()
            return
        if (result.unplaced > 0)
            this._SetStatus(result.unplaced . "個は指定位置に配置できませんでした")
        else if (result.corrected > 0)
            this._SetStatus(result.corrected . "個を再配置で補正しました")
    }

    static CloseDuplicates() {
        selected := this._GetSelectedItem()
        if !selected
            return
        if (selected.kind != "explorer") {
            this._SetStatus("重複終了はExplorerだけが対象です")
            return
        }
        if !selected.isFileSystem {
            this._SetStatus("ホームなどの仮想フォルダーは重複終了の対象外です")
            return
        }

        ; 一覧取得後に別パスへ移動したウィンドウを誤って閉じないよう、
        ; 実行時点のExplorer状態を再取得して選択HWNDの現在パスを基準にする。
        result := this._EnumerateExplorerWindows()
        if !result.ok {
            this._SetStatus("Explorer一覧を取得できないため重複終了を中止しました")
            return
        }
        currentItems := result.items
        keepItem := 0
        for item in currentItems {
            if (item.hwnd == selected.hwnd) {
                keepItem := item
                break
            }
        }
        if !keepItem {
            this.Items := currentItems
            this.ApplyFilter(this.GuiObj["Search"].Value)
            return
        }

        targets := []
        for item in currentItems {
            if (item.hwnd != keepItem.hwnd && StrCompare(item.path, keepItem.path, false) == 0)
                targets.Push(item.hwnd)
        }
        if (targets.Length == 0) {
            this._SetStatus("同じパスの重複Explorerはありません: " . keepItem.path)
            return
        }

        closedCount := 0
        for hwnd in targets {
            if this._IsExplorerWindow(hwnd) {
                try {
                    WinClose("ahk_id " . hwnd)
                    closedCount += 1
                }
            }
        }
        this._SetStatus(closedCount . "個の重複Explorerを閉じました: " . keepItem.path)
        SetTimer(() => this.Refresh(), -250)
    }

    static _CreateGui() {
        guiObj := Gui("+AlwaysOnTop +ToolWindow -MaximizeBox -MinimizeBox", "Explorer Switcher")
        guiObj.SetFont("s10", "Yu Gothic UI")
        guiObj.MarginX := 12
        guiObj.MarginY := 10

        search := guiObj.Add("Edit", "xm ym w796 vSearch")
        try DllCall("user32\SendMessageW", "ptr", search.Hwnd, "uint", this.EM_SETCUEBANNER,
            "ptr", 1, "wstr", "名前・パス・タイトルを検索（空白区切りでAND検索）", "ptr")

        guiObj.SetFont("s9", "Yu Gothic UI")
        closeOnBlur := guiObj.Add("Checkbox", "xm y+7 w175 vCloseOnFocusLossCheck",
            "外側クリックで閉じる")
        closeOnBlur.Value := this.CloseOnFocusLoss ? 1 : 0
        keepOpen := guiObj.Add("Checkbox", "x+14 yp w155 vKeepOpenAfterActivateCheck",
            "切替後も開く")
        keepOpen.Value := this.KeepOpenAfterActivate ? 1 : 0
        includeApps := guiObj.Add("Checkbox", "x+14 yp w135 vIncludeAppsCheck",
            "アプリも表示")
        includeApps.Value := this.IncludeApps ? 1 : 0
        arrange := guiObj.Add("Button", "x708 yp-4 w100 h27 vArrangeButton", "▦ 整列")

        guiObj.SetFont("s10", "Yu Gothic UI")
        lv := guiObj.Add("ListView", "xm y+7 w796 r12 Grid NoSort -Multi vResults", ["名前", "🗕", "配置", "パス / タイトル"])
        this.ImageListId := IL_Create(16, 16, false)
        this.IconIndexes := Map()
        lv.SetImageList(this.ImageListId)
        lv.ModifyCol(1, 206)
        lv.ModifyCol(2, "40 Center")
        lv.ModifyCol(3, "48 Center")
        lv.ModifyCol(4, 481)
        this._SetListColumnOrder(lv)
        ; 描画ごとのWM_NOTIFY判定で毎回コントロールを引かないよう控えておく。
        this._resultsHwnd := lv.Hwnd

        guiObj.SetFont("s8", "Yu Gothic UI")
        guiObj.Add("Text", "xm y+7 w796 h1 +0x10")
        guiObj.Add("Text", "xm y+6 w796 h18 +0x8000 vStatus", "0件")
        guiObj.Add("Text", "xm y+1 w796 h50 c707070 vHelp",
            "Ctrl+F 検索  ·  ↑↓ 選択  ·  Enter 切替  ·  Shift+Enter 最小化/復元  ·  Ctrl+C コピー  ·  Ctrl+P 登録  ·  1–9 切替"
            . "`nCtrl+M 全最小化  ·  Ctrl+Del 重複終了  ·  Ctrl+1–4 配置指定  ·  Ctrl+0 解除"
            . "  ·  Ctrl+G 整列  ·  F5 更新"
            . "`nCtrl+Shift+1–9 番号変更  ·  Ctrl+Shift+P 全解除  ·  Esc クリア/閉じる")

        this.GuiObj := guiObj
        search.OnEvent("Change", (ctrl, *) => this._OnSearchChanged(ctrl.Value))
        closeOnBlur.OnEvent("Click", (ctrl, *) => this.SetCloseOnFocusLoss(ctrl.Value))
        keepOpen.OnEvent("Click", (ctrl, *) => this.SetKeepOpenAfterActivate(ctrl.Value))
        includeApps.OnEvent("Click", (ctrl, *) => this.SetIncludeApps(ctrl.Value))
        arrange.OnEvent("Click", (*) => this.ArrangeOnCurrentMonitors())
        lv.OnEvent("Click", (ctrl, row) => this._HandleListClick(ctrl, row))
        lv.OnEvent("DoubleClick", (ctrl, row) => this._HandleListDoubleClick(ctrl, row))
        lv.OnEvent("ColClick", (ctrl, column) => this._HandleColumnClick(column))
        guiObj.OnEvent("Close", (*) => this.Hide())
        guiObj.OnEvent("Escape", (*) => this.HandleEscape())
    }

    static _OnSearchChanged(query) {
        this._lastTypeTick := A_TickCount
        this.ApplyFilter(query)
    }

    static _HandleListClick(lv, row) {
        subItem := this._GetListSubItemAtCursor(lv)
        if (row && subItem == 1) {
            this.ToggleRowVisibility(row)
            return
        }
        if (row && subItem == 2) {
            this.ShowLayoutSlotMenu(row)
            return
        }
        this.FocusSearch()
    }

    static _HandleColumnClick(column) {
        if (column == 2)
            this.MinimizeAll()
        else if (column == 3)
            this.ClearAllLayoutSlots()
    }

    static _HandleListDoubleClick(lv, row) {
        ; 表示切替アイコンのダブルクリックで、直後にExplorerへ切り替えない。
        subItem := this._GetListSubItemAtCursor(lv)
        if (!row || subItem == 1 || subItem == 2)
            return
        this.ActivateSelected()
    }

    static _StartNotifyHook() {
        if this._notifyHooked
            return
        OnMessage(this.WM_NOTIFY, this._notifyFn)
        this._notifyHooked := true
    }

    static _StopNotifyHook() {
        if !this._notifyHooked
            return
        OnMessage(this.WM_NOTIFY, this._notifyFn, 0)
        this._notifyHooked := false
    }

    static _OnNotify(wParam, lParam, msg, hwnd) {
        ; 描画ごとに呼ばれる高頻度パス。まず自分のListView宛てかだけを見て、
        ; 他GUIからの通知は最小コストで抜ける。
        if !lParam
            return
        hwndFrom := NumGet(lParam, 0, "ptr")
        if (hwndFrom != this._resultsHwnd)
            return
        code := NumGet(lParam, A_PtrSize * 2, "int")
        if (code != this.NM_CUSTOMDRAW)
            return

        stageOffset := A_PtrSize == 8 ? 24 : 12
        stage := NumGet(lParam, stageOffset, "uint")
        if (stage == this.CDDS_PREPAINT)
            return this.CDRF_NOTIFYITEMDRAW
        if (stage != this.CDDS_ITEMPREPAINT)
            return

        itemOffset := A_PtrSize == 8 ? 56 : 36
        colorOffset := A_PtrSize == 8 ? 80 : 48
        row := NumGet(lParam, itemOffset, "uptr") + 1
        if (row < 1 || row > this.FilteredItems.Length
            || !this.FilteredItems[row].isMinimized)
            return

        ; COLORREFは0x00BBGGRR。グレーはRGB/BGRが同値。
        NumPut("uint", this.MINIMIZED_TEXT_COLOR, lParam, colorOffset)
        ; 色指定だけなら既定描画へ戻す。CDRF_NEWFONTを返すと環境によって
        ; ListView側がclrTextを既定色で上書きすることがある。
        return 0
    }

    static _GetListSubItemAtCursor(lv) {
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mouseX, &mouseY)
        point := Buffer(8, 0)
        NumPut("int", mouseX, point, 0)
        NumPut("int", mouseY, point, 4)
        DllCall("user32\ScreenToClient", "ptr", lv.Hwnd, "ptr", point)

        hitInfo := Buffer(24, 0)
        NumPut("int", NumGet(point, 0, "int"), hitInfo, 0)
        NumPut("int", NumGet(point, 4, "int"), hitInfo, 4)
        NumPut("int", -1, hitInfo, 12)
        NumPut("int", -1, hitInfo, 16)
        DllCall("user32\SendMessageW", "ptr", lv.Hwnd,
            "uint", this.LVM_SUBITEMHITTEST, "ptr", 0, "ptr", hitInfo, "ptr")
        return NumGet(hitInfo, 12, "int") >= 0 ? NumGet(hitInfo, 16, "int") : -1
    }

    ; 列挙結果は {ok, items} で返す。COM列挙は時間がかかることがあり、その最中に
    ; タイマーやホットキーが割り込むため、成否をstaticフラグで持つと取り違える。
    static _EnumerateVisibleItems() {
        result := this._EnumerateExplorerWindows()
        if !result.ok
            return result

        items := result.items
        if this.IncludeApps
            this._AppendApplicationWindows(items)
        this._PruneWindowState(items)
        for item in items
            item.isPinned := this.PinnedHwnds.Has(item.hwnd)
        this._ApplyOrderLock(items)
        this._SortItems(items)
        return {ok: true, items: items}
    }

    ; rankはZ順そのものなので、最小化・復元・切替のたびに全ウィンドウの値が動く。
    ; そのまま並べ替えると、クリックした直後に行が入れ替わって「触っていない行の
    ; 状態が変わった」ように見え、次のクリックも別の行に当たる。
    ; 表示中は開いた時点の並びを固定し、新しいウィンドウは末尾に足す。
    static _ApplyOrderLock(items) {
        if !(this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd)) {
            this._orderLock.Clear()
            this._orderLockNext := 0
            return
        }

        unknown := []
        for item in items {
            if !this._orderLock.Has(item.hwnd)
                unknown.Push(item)
        }
        if unknown.Length {
            ; 初回（開いた直後）はここで全件が確定するため、現在のZ順を尊重する。
            this._SortItems(unknown)
            for item in unknown {
                this._orderLockNext += 1
                this._orderLock[item.hwnd] := this._orderLockNext
            }
        }
        for item in items
            item.rank := this._orderLock[item.hwnd]
    }

    static _EnumerateExplorerWindows() {
        items := []
        seenHwnds := Map()
        zRanks := Map()

        try {
            for rank, hwnd in WinGetList()
                zRanks[hwnd] := rank
        }

        try shellWindows := ComObject("Shell.Application").Windows
        catch
            return {ok: false, items: items}

        ; LocationNameとDocument.Folder.Self.Pathはexplorer.exeへのプロセス跨ぎ呼び出しで、
        ; 実測ではこの列挙の約8割を占める。Explorerのタイトルは現在のフォルダー名を
        ; 反映するため、タイトルが変わらない限り前回の結果を使い回す。
        ; ただし同名の別フォルダーへ移動するとタイトルが変わらないので、
        ; FULL_QUERY_EVERY回に1回はキャッシュを捨ててCOMから取り直す。
        useCache := this._fullQueryCountdown > 0
        this._fullQueryCountdown := useCache
            ? this._fullQueryCountdown - 1
            : this.FULL_QUERY_EVERY

        for window in shellWindows {
            try {
                hwnd := window.HWND + 0
                if (!this._IsExplorerWindow(hwnd) || seenHwnds.Has(hwnd))
                    continue

                seenHwnds[hwnd] := true
                title := WinGetTitle("ahk_id " . hwnd)
                cached := useCache && this._pathCache.Has(hwnd) ? this._pathCache[hwnd] : 0
                if (cached && cached.title == title) {
                    path := cached.path
                    displayName := cached.displayName
                    isFileSystem := cached.isFileSystem
                } else {
                    try locationName := Trim(window.LocationName)
                    catch
                        locationName := ""
                    try path := window.Document.Folder.Self.Path
                    catch
                        path := ""

                    isFileSystem := this._IsFileSystemPath(path)
                    if isFileSystem {
                        path := this._NormalizePath(path)
                        SplitPath(path, &displayName)
                        if (displayName == "")
                            displayName := path
                    } else {
                        ; ホーム、PC、ごみ箱なども実在するExplorerウィンドウとして残す。
                        ; これらは通常パスを持たないため、COMの表示名を検索・詳細表示に使う。
                        displayName := locationName != "" ? locationName : this._ExplorerNameFromTitle(title)
                        if (displayName == "")
                            displayName := "Explorer"
                        path := locationName != "" ? locationName : displayName
                    }
                    this._pathCache[hwnd] := {title: title, path: path,
                        displayName: displayName, isFileSystem: isFileSystem}
                }

                rank := zRanks.Has(hwnd) ? zRanks[hwnd] : 100000 + items.Length
                items.Push({
                    hwnd: hwnd,
                    kind: "explorer",
                    title: title,
                    path: path,
                    displayName: displayName,
                    isFileSystem: isFileSystem,
                    isMinimized: WinGetMinMax("ahk_id " . hwnd) == -1,
                    isPinned: false,
                    duplicateCount: 1,
                    rank: rank
                })
            }
        }

        pathCounts := Map()
        for item in items {
            if !item.isFileSystem
                continue
            key := StrLower(item.path)
            pathCounts[key] := pathCounts.Has(key) ? pathCounts[key] + 1 : 1
        }
        for item in items {
            if item.isFileSystem
                item.duplicateCount := pathCounts[StrLower(item.path)]
        }

        for item in items
            item.isPinned := this.PinnedHwnds.Has(item.hwnd)

        ; 閉じたExplorer分のキャッシュを溜め込まない。
        this._PruneStaleKeys(this._pathCache, seenHwnds)

        this._SortItems(items)
        return {ok: true, items: items}
    }

    static _AppendApplicationWindows(items) {
        seenHwnds := Map()
        for item in items
            seenHwnds[item.hwnd] := true

        for rank, hwnd in WinGetList() {
            try {
                if (seenHwnds.Has(hwnd)
                    || (this._GuiExists() && hwnd == this.GuiObj.Hwnd)
                    || !DllCall("user32\IsWindowVisible", "ptr", hwnd))
                    continue

                title := Trim(WinGetTitle("ahk_id " . hwnd))
                if (title == "")
                    continue
                cls := WinGetClass("ahk_id " . hwnd)
                if (cls == "Shell_TrayWnd" || cls == "Progman" || cls == "WorkerW")
                    continue

                exStyle := WinGetExStyle("ahk_id " . hwnd)
                isAppWindow := (exStyle & 0x00040000) != 0
                if ((exStyle & 0x00000080) && !isAppWindow)
                    continue
                if (exStyle & 0x08000000)
                    continue
                owner := DllCall("user32\GetWindow", "ptr", hwnd, "uint", 4, "ptr")
                if (owner && !isAppWindow)
                    continue

                cloaked := Buffer(4, 0)
                if (DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd,
                    "uint", 14, "ptr", cloaked, "uint", 4, "int") == 0
                    && NumGet(cloaked, 0, "uint") != 0)
                    continue

                processName := WinGetProcessName("ahk_id " . hwnd)
                if (StrCompare(processName, "explorer.exe", false) == 0)
                    continue
                try exePath := WinGetProcessPath("ahk_id " . hwnd)
                catch
                    exePath := ""
                displayName := RegExReplace(processName, "i)\.exe$")
                if (displayName == "")
                    displayName := title

                items.Push({
                    hwnd: hwnd,
                    kind: "app",
                    title: title,
                    path: exePath,
                    displayName: displayName,
                    isFileSystem: false,
                    isMinimized: WinGetMinMax("ahk_id " . hwnd) == -1,
                    isPinned: false,
                    duplicateCount: 1,
                    rank: rank
                })
                seenHwnds[hwnd] := true
            } catch {
                continue
            }
        }
    }

    static _SortItems(items) {
        ; AutoHotkey v2標準配列に依存しない、小規模リスト向けの安定挿入ソート。
        loop items.Length - 1 {
            i := A_Index + 1
            current := items[i]
            j := i - 1
            while (j >= 1 && this._ComesAfter(items[j], current)) {
                items[j + 1] := items[j]
                j -= 1
            }
            items[j + 1] := current
        }
    }

    static _ItemsEquivalent(leftItems, rightItems) {
        if (leftItems.Length != rightItems.Length)
            return false

        leftByHwnd := Map()
        for item in leftItems
            leftByHwnd[item.hwnd] := item

        for right in rightItems {
            if !leftByHwnd.Has(right.hwnd)
                return false
            left := leftByHwnd[right.hwnd]
            if (left.kind != right.kind
                || StrCompare(left.path, right.path, false) != 0
                || left.displayName != right.displayName
                || left.title != right.title
                || left.isPinned != right.isPinned
                || left.isMinimized != right.isMinimized
                || left.duplicateCount != right.duplicateCount)
                return false
        }
        return true
    }

    static _CountMatches(items, query) {
        tokens := this._TokenizeQuery(query)
        count := 0
        for item in items {
            if this._ItemMatchesTokens(item, tokens)
                count += 1
        }
        return count
    }

    static _TokenizeQuery(query) {
        normalized := Trim(StrReplace(query, "　", " "))
        if (normalized == "")
            return []

        tokens := []
        for token in StrSplit(normalized, " ") {
            if (token != "")
                tokens.Push(token)
        }
        return tokens
    }

    static _ItemMatchesTokens(item, tokens) {
        for token in tokens {
            if !(InStr(item.displayName, token, false)
                || InStr(item.path, token, false)
                || InStr(item.title, token, false))
                return false
        }
        return true
    }

    static _RestoreListScroll(lv, topIndex) {
        count := lv.GetCount()
        if (count == 0)
            return

        topIndex := Min(Max(topIndex, 0), count - 1)
        perPage := SendMessage(this.LVM_GETCOUNTPERPAGE, 0, 0, lv)
        if (perPage <= 0)
            perPage := 1

        ; 先に旧ビューポートの末尾を可視化してから先頭を可視化すると、
        ; topIndexが可能な範囲で再びリスト上端に配置される。
        bottomIndex := Min(count - 1, topIndex + perPage - 1)
        SendMessage(this.LVM_ENSUREVISIBLE, bottomIndex, 0, lv)
        SendMessage(this.LVM_ENSUREVISIBLE, topIndex, 0, lv)
    }

    static _ComesAfter(left, right) {
        if (left.isPinned != right.isPinned)
            return !left.isPinned && right.isPinned
        if (left.rank != right.rank)
            return left.rank > right.rank
        return StrCompare(left.displayName, right.displayName, false) > 0
    }

    ; HWNDはOSが再利用するため、閉じたウィンドウ由来の指定を残すと無関係な
    ; ウィンドウがピンや配置指定を引き継いでしまう。列挙のたびに掃除する。
    static _PruneWindowState(items) {
        existingHwnds := Map()
        for item in items
            existingHwnds[item.hwnd] := true

        this._PruneStaleKeys(this.PinnedHwnds, existingHwnds)
        this._PruneStaleKeys(this.FavoriteNumbers, existingHwnds)
        this._PruneStaleKeys(this.LayoutSlots, existingHwnds)
    }

    static _PruneStaleKeys(target, existingHwnds) {
        staleHwnds := []
        for hwnd in target {
            if !existingHwnds.Has(hwnd)
                staleHwnds.Push(hwnd)
        }
        for hwnd in staleHwnds
            target.Delete(hwnd)
    }

    static _NormalizePath(path) {
        while (StrLen(path) > 3 && SubStr(path, -1) == "\")
            path := SubStr(path, 1, -1)
        return path
    }

    static _ExplorerNameFromTitle(title) {
        ; OSの表示言語に依存する末尾は決め打ちせず、一般的なExplorerの区切りだけ除く。
        name := RegExReplace(Trim(title), "i)\s+-\s+(エクスプローラー|File Explorer)$")
        return Trim(name)
    }

    static _IsFileSystemPath(path) {
        if (path == "")
            return false
        ; DirExistは切断中のネットワークパスで待たされるため、Explorerが返した
        ; ドライブパスまたはUNC/拡張パスであることだけを軽量に確認する。
        return RegExMatch(path, "i)^[A-Z]:\\") || SubStr(path, 1, 2) == "\\"
    }

    static _IsExplorerWindow(hwnd) {
        if !hwnd || !WinExist("ahk_id " . hwnd)
            return false
        try cls := WinGetClass("ahk_id " . hwnd)
        catch
            return false
        return cls == "CabinetWClass" || cls == "ExploreWClass"
    }

    static _IsItemWindowValid(item) {
        if !item || !item.hwnd || !DllCall("user32\IsWindow", "ptr", item.hwnd)
            return false
        return item.kind == "explorer" ? this._IsExplorerWindow(item.hwnd) : true
    }

    static _ActivateHwnd(hwnd) {
        if !hwnd || !DllCall("user32\IsWindow", "ptr", hwnd)
            return
        try {
            if WinGetMinMax("ahk_id " . hwnd) == -1
                WinRestore("ahk_id " . hwnd)
            WinActivate("ahk_id " . hwnd)
        }
    }

    static _ActivateKeepingSwitcher(hwnd) {
        ; このWinActivateによるフォーカス喪失では自動で閉じない。Switcherが再び
        ; アクティブになった時点で通常のフォーカス監視へ戻す。
        this._ignoreFocusLossUntilReactivated := true
        this._ActivateHwnd(hwnd)
    }

    ; WinMinimize等の直後はOSが別ウィンドウへフォーカスを渡す場合があるため、
    ; 即時とアニメーション完了後の2段階でSwitcherへ戻す。
    static _RefocusSwitcherSoon(hwnd) {
        this._RefocusSwitcher(hwnd)
        SetTimer(() => this._RefocusSwitcher(hwnd), this.REFOCUS_DELAY)
    }

    static _RefocusSwitcher(hwnd) {
        if !(this._GuiExists() && this.GuiObj.Hwnd == hwnd)
            return
        if !DllCall("user32\IsWindowVisible", "ptr", hwnd)
            return
        try {
            WinActivate("ahk_id " . hwnd)
            this.GuiObj["Search"].Focus()
        }
    }

    static _MoveSelection(delta) {
        if (this.FilteredItems.Length == 0)
            return
        lv := this.GuiObj["Results"]
        row := lv.GetNext()
        if (row == 0)
            row := delta > 0 ? 1 : this.FilteredItems.Length
        else {
            lv.Modify(row, "-Select -Focus")
            row += delta
            if (row < 1)
                row := this.FilteredItems.Length
            else if (row > this.FilteredItems.Length)
                row := 1
        }
        lv.Modify(row, "Select Focus Vis")
    }

    static _GetSelectedItem() {
        if !this._GuiExists()
            return 0
        row := this.GuiObj["Results"].GetNext()
        if (row < 1 || row > this.FilteredItems.Length)
            return 0
        return this.FilteredItems[row]
    }

    static _GetSelectedHwnd() {
        item := this._GetSelectedItem()
        return item ? item.hwnd : 0
    }

    static _SelectHwnd(hwnd) {
        if !hwnd || !this._GuiExists()
            return
        lv := this.GuiObj["Results"]
        for row, item in this.FilteredItems {
            if (item.hwnd == hwnd) {
                currentRow := lv.GetNext()
                if currentRow
                    lv.Modify(currentRow, "-Select -Focus")
                lv.Modify(row, "Select Focus Vis")
                return
            }
        }
    }

    static _IsImeComposing() {
        if !this._GuiExists()
            return false
        editHwnd := this.GuiObj["Search"].Hwnd
        hIMC := DllCall("imm32\ImmGetContext", "ptr", editHwnd, "ptr")
        if !hIMC
            return false
        composing := DllCall("imm32\ImmGetCompositionStringW", "ptr", hIMC,
            "uint", 0x0008, "ptr", 0, "ptr", 0) > 0
        DllCall("imm32\ImmReleaseContext", "ptr", editHwnd, "ptr", hIMC)
        return composing
    }

    static _UpdateStatus() {
        this._SetStatus()
    }

    static _SetStatus(message := "") {
        if !this._GuiExists()
            return
        countText := this.FilteredItems.Length . " / " . this.Items.Length . " 件"
        this.GuiObj["Status"].Text := countText . (message != "" ? "    " . message : "")
    }

    static _StartRefreshTimer() {
        this._StopRefreshTimer()
        SetTimer(this._refreshTimerFn, this.REFRESH_INTERVAL)
    }

    static _StopRefreshTimer() {
        if this._refreshTimerFn
            SetTimer(this._refreshTimerFn, 0)
    }

    static _RefreshWhileVisible() {
        if !this._GuiExists() {
            this._StopRefreshTimer()
            return
        }
        if !DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd) {
            this._StopRefreshTimer()
            return
        }
        ; 打鍵の直後は絞り込み描画と重ねない。次のtickで拾えばよい。
        if (A_TickCount - this._lastTypeTick < this.TYPING_QUIET_PERIOD)
            return
        this.Refresh()
    }

    static _StartCacheTimer() {
        SetTimer(this._cacheTimerFn, this.CACHE_REFRESH_INTERVAL)
    }

    static _StopCacheTimer() {
        if this._cacheTimerFn
            SetTimer(this._cacheTimerFn, 0)
    }

    static _RefreshCacheWhileHidden() {
        if (this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd))
            return
        ; しばらく使われていなければ止める。次にShowした時点で改めて取り直す。
        if (A_TickCount - this._lastUseTick > this.CACHE_IDLE_TIMEOUT) {
            this._StopCacheTimer()
            return
        }
        if this._refreshBusy
            return

        this._refreshBusy := true
        try {
            result := this._EnumerateVisibleItems()
            if result.ok
                this.Items := result.items
        } finally {
            this._refreshBusy := false
        }
    }

    static _StartFocusWatch() {
        this._StopFocusWatch()
        if !this.CloseOnFocusLoss
            return
        this._focusWatchBorn := A_TickCount
        this._focusEverActive := WinActive("ahk_id " . this.GuiObj.Hwnd) != 0
        SetTimer(this._focusWatchTimerFn, this.FOCUS_WATCH_INTERVAL)
    }

    static _StopFocusWatch() {
        if this._focusWatchTimerFn
            SetTimer(this._focusWatchTimerFn, 0)
        this._focusEverActive := false
    }

    static _FocusWatchTick() {
        if !this.CloseOnFocusLoss {
            this._StopFocusWatch()
            return
        }
        if !(this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd)) {
            this._StopFocusWatch()
            return
        }
        if WinActive("ahk_id " . this.GuiObj.Hwnd) {
            this._focusEverActive := true
            this._ignoreFocusLossUntilReactivated := false
            return
        }
        if this._ignoreFocusLossUntilReactivated
            return
        if (A_TickCount < this._suspendAutoCloseUntil)
            return

        ; 表示直後にまだ一度もフォーカスを得ていない場合だけ、OSの初期フォーカス
        ; 競合として短時間リトライする。一度アクティブになった後の喪失は外側クリック。
        if (!this._focusEverActive && A_TickCount - this._focusWatchBorn < 500) {
            try WinActivate("ahk_id " . this.GuiObj.Hwnd)
            return
        }
        this.Hide()
    }
}
