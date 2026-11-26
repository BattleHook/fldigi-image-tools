#Requires AutoHotkey v2.0
#SingleInstance Ignore
#ErrorStdOut
#Warn All, StdOut
;@Ahk2Exe-SetMainIcon FldigiImageTools.ico
#Include CleanerCore.ahk
#Include WefaxEditor.ahk

OnError(CleanerUnhandled)
linkedPreview := A_Args.Length && A_Args[1] = "--preview-linked"
if A_Args.Length && ((linkedPreview && A_Args.Length != 3) || (!linkedPreview && A_Args[1] != "--preview"))
    throw ValueError("Usage: FldigiLogbookCleaner.ahk [--preview [copied-PNG-path ...] | --preview-linked original.png enhanced.png]")
previewImages := A_Args.Clone()
if previewImages.Length
    previewImages.RemoveAt(1)
TraySetIcon(A_IsCompiled ? A_ScriptFullPath : A_ScriptDir "\FldigiImageTools.ico", 1, true)
window := CleanerWindow(A_Args.Length > 0, previewImages, linkedPreview)
window.Show()

CleanerUnhandled(problem, mode) {
    global window
    if IsSet(window)
        window.Report(problem, "Unexpected error (" mode ")")
    else
        CleanerReport(problem, "Startup (" mode ")")
    return 1
}

class CleanerWindow {
    __New(preview, previewImages, linkedPreview := false) {
        this.preview := preview
        this.previewImages := previewImages
        this.linkedPreview := linkedPreview
        this.title := "FLdigi Image Tools" (preview ? " - isolated preview" : "")
        this.ini := A_ScriptDir "\Cleaner.ini"
        this.rows := []
        this.lastBackup := ""
        this.gui := Gui("+Resize +MinSize620x460", this.title)
        this.gui.BackColor := "343434"
        this.gui.MarginX := 20
        this.gui.MarginY := 16
        dark := Buffer(4, 0)
        NumPut("Int", 1, dark)
        DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", this.gui.Hwnd, "UInt", 20, "Ptr", dark, "UInt", 4)
        this.gui.SetFont("s15 bold cWhite", "Segoe UI")
        this.gui.AddText("x20 y17 w580 h30", "FLDIGI IMAGE TOOLS")
        this.gui.SetFont("s10 norm cFFD060", "Segoe UI")
        this.gui.AddText("x20 y51 w580 h24", "IMAGE LOG REVIEW  /  HAM SHACK UTILITIES")
        this.gui.SetFont("s10 norm cWhite", "Segoe UI")
        this.gui.AddText("x20 y86 w280 h22", "ADIF LOGBOOK")
        this.settingsButton := this.gui.AddButton("x496 y79 w104 h27", "SETTINGS")
        this.settingsButton.OnEvent("Click", ObjBindMethod(this, "OpenSettings"))
        this.logPath := this.gui.AddEdit("x20 y111 w580 h27 ReadOnly cBlack",
            preview ? "Synthetic logbook - no station files" : this.ini)
        this.summary := this.gui.AddText("x20 y148 w368 h38", "Scan the logbook to look for missing images.")
        this.checkAllButton := this.gui.AddButton("x396 y151 w96 h28 Disabled", "Check All")
        this.checkAllButton.OnEvent("Click", ObjBindMethod(this, "CheckRows", true))
        this.uncheckAllButton := this.gui.AddButton("x500 y151 w100 h28 Disabled", "Uncheck All")
        this.uncheckAllButton.OnEvent("Click", ObjBindMethod(this, "CheckRows", false))
        this.list := this.gui.AddListView("x20 y189 w580 h140 Checked -Multi NoSortHdr Background272727 cWhite",
            ["Date / time (UTC)", "Mode", "Missing image", "Path checked"])
        this.list.OnEvent("ItemCheck", ObjBindMethod(this, "SelectionChanged"))
        this.list.ModifyCol(1, 150)
        this.list.ModifyCol(2, 92)
        this.list.ModifyCol(3, 300)
        this.captionLabel := this.gui.AddText("x20 y340 w580 h20", "PATH CHECKED  /  select a row to see the full path")
        this.caption := this.gui.AddEdit("x20 y366 w580 h27 ReadOnly cBlack")
        this.list.OnEvent("ItemSelect", ObjBindMethod(this, "ShowPath"))
        this.gui.SetFont("s10 cFFD060", "Segoe UI")
        this.status := this.gui.AddText("x20 y401 w580 h42",
            "Read-only until Apply. Close FLdigi before applying changes.")
        this.gui.SetFont("s10 cWhite", "Segoe UI")
        this.backupButton := this.gui.AddButton("x434 y397 w166 h28 Disabled", "Open Backup Folder")
        this.backupButton.OnEvent("Click", ObjBindMethod(this, "OpenBackupFolder"))
        this.scanButton := this.gui.AddButton("x20 y453 w116 h32 Default", "SCAN")
        this.scanButton.OnEvent("Click", ObjBindMethod(this, "Scan"))
        this.applyButton := this.gui.AddButton("x144 y453 w220 h32 Disabled", "APPLY SELECTED REMOVALS")
        this.applyButton.OnEvent("Click", ObjBindMethod(this, "Apply"))
        this.imagesButton := this.gui.AddButton("x372 y453 w116 h32", "WEFAX IMAGES")
        this.imagesButton.OnEvent("Click", (*) => this.BrowseImages())
        this.closeButton := this.gui.AddButton("x372 y453 w100 h32", "CLOSE")
        this.closeButton.OnEvent("Click", (*) => ExitApp())
        this.gui.OnEvent("Size", ObjBindMethod(this, "Resize"))
        this.gui.OnEvent("Close", (*) => ExitApp())
        this.gui.OnEvent("Escape", (*) => ExitApp())
    }

    Show() {
        MonitorGetWorkArea(MonitorGetPrimary(), &left, &top, &right, &bottom)
        scale := A_ScreenDPI / 96
        width := Min(980, Floor((right - left) / scale) - 48)
        height := Min(570, Floor((bottom - top) / scale) - 70)
        this.gui.Show("w" Max(620, width) " h" Max(460, height))
        if this.preview {
            this.Scan()
        } else {
            try this.logPath.Value := CleanerConfig(this.ini).log
            catch as problem
                this.Report(problem, "Reading settings")
        }
    }

    Resize(gui, minMax, width, height) {
        if minMax = -1
            return
        inner := width - 40
        footer := height - 122
        this.settingsButton.Move(width - 124)
        this.logPath.Move(, , inner)
        this.summary.Move(, , inner - 212)
        this.checkAllButton.Move(width - 224)
        this.uncheckAllButton.Move(width - 120)
        this.list.Move(, , inner, footer - 224)
        this.list.ModifyCol(4, Max(115, inner - 570))
        this.caption.Move(, footer - 13, inner)
        this.captionLabel.Move(, footer - 35, inner)
        this.status.Move(, footer + 24, inner - 174)
        this.backupButton.Move(width - 186, footer + 20)
        this.scanButton.Move(, height - 48)
        this.applyButton.Move(, height - 48)
        this.imagesButton.Move(, height - 48)
        this.closeButton.Move(width - 120, height - 48)
        ; Redraw the moved native controls and clear their previous positions.
        DllCall("RedrawWindow", "Ptr", gui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
    }

    Clear() {
        this.rows := []
        this.list.Delete()
        this.caption.Value := ""
        this.SelectionChanged()
    }

    OpenSettings(*) {
        try {
            original := this.preview ? 0 : CleanerRead(this.ini)
            logValue := this.preview ? "C:\Demo\fldigi.files\logs\logbook.adi" : IniRead(this.ini, "Logbook", "Path", "")
            folder := this.preview ? "C:\Demo\fldigi\WEFAX" : IniRead(this.ini, "Rule WEFAX", "Folder", "")
            dialog := Gui("+Owner" this.gui.Hwnd, "FLdigi Image Tools - Settings")
            dialog.BackColor := "343434"
            dialog.MarginX := 20
            dialog.MarginY := 16
            dialog.SetFont("s10 cWhite", "Segoe UI")
            dialog.AddText("w556", "ADIF LOGBOOK FILE")
            logEdit := dialog.AddEdit("xm w452 cBlack", logValue)
            logBrowse := dialog.AddButton("x+8 yp w96", "Browse...")
            dialog.AddText("xm y+16 w556", "WEFAX IMAGE FOLDER")
            folderEdit := dialog.AddEdit("xm w452 cBlack", folder)
            folderBrowse := dialog.AddButton("x+8 yp w96", "Browse...")
            notice := dialog.AddText("xm y+14 w556 h50 cFFD060", this.preview
                ? "ISOLATED PREVIEW - sample paths only. Saving is disabled."
                : "Changes are saved to Cleaner.ini beside the app. No restart is needed.")
            save := dialog.AddButton("xm y+6 w100 h30 Default", "Save")
            cancel := dialog.AddButton("x+8 yp w100 h30", "Cancel")
            close := (*) => this.CloseSettings(dialog)
            dialog.OnEvent("Close", close)
            dialog.OnEvent("Escape", close)
            cancel.OnEvent("Click", close)
            save.OnEvent("Click", (*) => this.SaveSettings(dialog, notice, original, logEdit.Value, folderEdit.Value))
            logBrowse.OnEvent("Click", (*) => this.BrowseSetting(dialog, logEdit, false, notice))
            folderBrowse.OnEvent("Click", (*) => this.BrowseSetting(dialog, folderEdit, true, notice))
            if this.preview
                save.Enabled := logBrowse.Enabled := folderBrowse.Enabled := false
            this.gui.Opt("+Disabled")
            try WefaxShowRelative(dialog, this.gui.Hwnd)
            catch {
                close.Call()
                throw
            }
        } catch as problem {
            this.Report(problem, "Opening Settings")
        }
    }

    BrowseSetting(dialog, edit, folder, notice) {
        try {
            dialog.Opt("+OwnDialogs")
            path := CleanerExpand(edit.Value)
            selected := folder ? DirSelect(DirExist(path) ? "*" path : "", 0, "Choose the WEFAX image folder")
                : FileSelect(3, path, "Choose the FLdigi logbook", "ADIF files (*.adi; *.adif)")
            if selected != ""
                edit.Value := selected
        } catch as problem {
            this.ReportSettings(notice, problem, "Browsing for a path")
        }
    }

    SaveSettings(dialog, notice, original, logValue, folder) {
        if this.preview
            return
        try config := CleanerSavePaths(this.ini, logValue, folder, original)
        catch as problem {
            this.ReportSettings(notice, problem, "Could not save settings")
            return
        }
        this.Clear()
        this.logPath.Value := config.log
        this.summary.Text := "Scan the logbook to look for missing images."
        this.status.Text := "Settings saved. Click Scan to use the new paths."
        this.CloseSettings(dialog)
    }

    ReportSettings(notice, problem, context) {
        CleanerReport(problem, context)
        notice.Text := context ": " problem.Message
    }

    CloseSettings(dialog) {
        this.gui.Opt("-Disabled")
        dialog.Destroy()
        WinActivate("ahk_id " this.gui.Hwnd)
    }

    Scan(*) {
        this.Clear()
        if this.preview {
            this.rows := [
                {date: "20260101", time: "090000", mode: "WEFAX", file: "demo_north_atlantic.png",
                 path: "C:\Demo\fldigi\WEFAX\demo_north_atlantic.png"},
                {date: "20260101", time: "100000", mode: "WEFAX", file: "demo_surface_chart.png",
                 path: "C:\Demo\fldigi\WEFAX\demo_surface_chart.png"}]
            this.Populate()
            this.list.Modify(1, "Select Focus")
            this.ShowPath(this.list, 1, true)
            this.summary.Text := "2 missing-image candidates  /  5 demo records"
            this.status.Text := "ISOLATED PREVIEW - synthetic records only. Apply is disabled."
            return true
        }
        try {
            this.config := CleanerConfig(this.ini)
            this.logPath.Value := this.config.log
            this.snapshot := CleanerRead(this.config.log)
            result := CleanerScan(this.snapshot, this.config.rules)
            this.rows := result.candidates
            this.Populate()
            this.summary.Text := this.rows.Length " missing-image candidate(s)  /  " result.total " log records"
                . (result.skipped ? "  /  " result.skipped " not verifiable" : "")
            unavailable := ""
            for name in result.missingFolders
                unavailable .= (unavailable = "" ? "" : ", ") name
            this.status.Text := unavailable = "" ? "Check the entries to remove. A backup is made before writing."
                : "Unavailable image folder(s): " unavailable ". Those entries were kept."
            return true
        } catch as problem {
            this.Clear()
            this.summary.Text := "Scan did not complete."
            this.Report(problem, "Scan")
            return false
        }
    }

    Populate() {
        for row in this.rows {
            date := RegExReplace(row.date, "^(\d{4})(\d{2})(\d{2})$", "$1-$2-$3")
            time := RegExReplace(row.time, "^(\d{2})(\d{2})(\d{2})?$", "$1:$2")
            this.list.Add("", date " " time, row.mode, row.file, row.path)
        }
        this.SelectionChanged()
    }

    ShowPath(list, row, selected) {
        if selected && this.rows.Has(row)
            this.caption.Value := this.rows[row].path
    }

    SelectionChanged(*) {
        checked := !!this.list.GetNext(0, "Checked")
        this.checkAllButton.Enabled := this.rows.Length > 0
        this.uncheckAllButton.Enabled := checked
        this.applyButton.Enabled := !this.preview && checked
    }

    CheckRows(check, *) {
        this.list.Modify(0, check ? "Check" : "-Check")
        this.SelectionChanged()
    }

    BrowseImages(initialRow := 1) {
        try {
            config := 0, snapshot := 0
            if this.preview {
                images := []
                for path in this.previewImages {
                    SplitPath(path, &filename)
                    images.Push({file: filename, path: path, enhanced: this.linkedPreview ? this.previewImages[2] : ""})
                    if this.linkedPreview
                        break
                }
                images.Push({file: "synthetic_weather_chart.png", path: "", enhanced: ""})
            } else {
                config := CleanerConfig(this.ini), snapshot := CleanerRead(config.log)
                images := CleanerScan(snapshot, config.rules).images
            }
            if !images.Length {
                this.status.Text := "No existing WEFAX PNGs linked in this logbook."
                return
            }
            browser := Gui("+Owner" this.gui.Hwnd, "WEFAX Images")
            browser.BackColor := "343434"
            browser.SetFont("s10 cWhite", "Segoe UI")
            work := WefaxOwnerWorkArea(this.gui.Hwnd), scale := A_ScreenDPI / 96
            width := Min(1126, Floor((work.right - work.left) / scale) - 40)
            panelWidth := Min(240, Floor((width - 340) / 2))
            if panelWidth < 120 || Floor((work.bottom - work.top) / scale) < 455
                throw Error("The current work area is too small for the two WEFAX preview panes.")
            listWidth := width - 26 - 2 * panelWidth
            originalX := listWidth + 24, enhancedX := originalX + panelWidth + 12
            browser.AddText("w" width, this.preview ? "Select a copied or synthetic PNG for the read-only preview."
                : "Select an existing log-linked PNG to preview or enhance.")
            list := browser.AddListView("xm y44 w" listWidth " h280 -Multi NoSortHdr Background272727 cWhite", ["Original PNG", "ENH reference"])
            for item in images
                list.Add("", item.file, item.enhanced ? "Linked" : "")
            list.ModifyCol(1, listWidth - 155)
            list.ModifyCol(2, 130)
            original := this.AddThumbnail(browser, originalX, panelWidth, "SELECTED ORIGINAL")
            enhanced := this.AddThumbnail(browser, enhancedX, panelWidth, "LINKED ENHANCED")
            notice := this.preview ? "ISOLATED PREVIEW - logbook updates and recycling are disabled."
                : "Recycling moves only the original. Close FLdigi before recycling."
            status := browser.AddText("xm y335 w" width " h40 cFFD060", notice)
            open := (*) => this.OpenImage(browser, status, config, snapshot, images, list.GetNext())
            browser.AddButton("xm y382 w144 Default", "OPEN IMAGE").OnEvent("Click", open)
            recycle := browser.AddButton("x168 y382 w190 Disabled", "MOVE TO RECYCLE BIN")
            update := (*) => this.UpdateThumbnails(list, original, enhanced, status, notice, recycle, images)
            recycle.OnEvent("Click", (*) => this.RecycleImage(browser, list, status, config, snapshot, images, update))
            list.OnEvent("ItemSelect", update)
            browser.OnEvent("Close", (*) => browser.Destroy())
            list.OnEvent("DoubleClick", open)
            list.Modify(initialRow, "Select Focus")
            update.Call()
            WefaxShowRelative(browser, this.gui.Hwnd)
            return browser
        } catch as problem {
            this.Report(problem, "WEFAX images")
        }
    }

    AddThumbnail(browser, x, width, label) {
        options := "x" x " w" width
        browser.AddText(options " y44 h20", label)
        return {x: x, width: width, image: browser.AddPicture(options " y68 h225"),
            details: browser.AddText(options " y300 h24")}
    }

    DrawThumbnail(pane, image) {
        scale := A_ScreenDPI / 96
        bitmap := WefaxPreviewBitmap(image, Floor(pane.width * scale), Floor(225 * scale))
        width := Max(1, Round(bitmap.width / scale)), height := Max(1, Round(bitmap.height / scale))
        pane.image.Value := "HBITMAP:" bitmap.handle
        pane.image.Move(pane.x + (pane.width - width) // 2, 68 + (225 - height) // 2, width, height)
        pane.details.Text := image.width " x " image.height " px"
    }

    UpdateThumbnails(list, original, enhanced, status, notice, recycle, images) {
        index := list.GetNext()
        for pane in [original, enhanced] {
            pane.image.Value := ""
            pane.details.Text := ""
        }
        status.Text := notice
        recycle.Enabled := false
        if !images.Has(index)
            return
        row := images[index]
        try {
            this.DrawThumbnail(original, row.path = "" ? WefaxDemo() : WefaxLoad(row.path))
            recycle.Enabled := !this.preview
        } catch as problem {
            CleanerReport(problem, "Loading WEFAX thumbnail")
            status.Text := "Thumbnail unavailable: " problem.Message
        }
        if row.enhanced = ""
            enhanced.details.Text := "No linked enhancement"
        else {
            try this.DrawThumbnail(enhanced, WefaxLoad(row.enhanced))
            catch as problem {
                CleanerReport(problem, "Loading linked enhanced WEFAX thumbnail")
                enhanced.details.Text := "Preview unavailable"
                status.Text := status.Text = notice ? "Enhanced thumbnail unavailable: " problem.Message
                    : status.Text "`nEnhanced thumbnail unavailable: " problem.Message
            }
        }
    }

    RecycleImage(browser, list, status, config, snapshot, images, update) {
        index := list.GetNext()
        if this.preview || !images.Has(index)
            return
        row := images[index]
        try {
            CleanerRequireFldigiClosed()
            if MsgBox("Move this original image to the Windows Recycle Bin?`n`n" row.path
                . "`n`nThe log entry and any enhanced image will be kept.",
                "WEFAX Images", "YesNo Default2 Icon! Owner" browser.Hwnd) != "Yes"
                return
            CleanerRecycleOriginal(config, snapshot, row, CleanerRequireFldigiClosed, CleanerWindowsRecycle)
            this.RemoveBrowserRows(list, images, index)
            update.Call()
            status.Text := "Original recycled. Log and enhanced image unchanged. Scan again to review cleanup candidates."
        } catch as problem {
            CleanerReport(problem, "Recycling WEFAX original")
            status.Text := problem.Message
        }
    }

    RemoveBrowserRows(list, images, index) {
        path := images[index].path
        previous := index - 1
        Loop images.Length {
            at := images.Length - A_Index + 1
            if images[at].path = path {
                if at < index
                    previous--
                images.RemoveAt(at)
                list.Delete(at)
            }
        }
        if images.Length
            list.Modify(Max(1, previous), "Select Focus Vis")
    }

    OpenImage(browser, status, config, snapshot, images, index) {
        if !images.Has(index)
            return
        try {
            row := images[index]
            if this.preview {
                image := row.path = "" ? WefaxDemo() : WefaxLoad(row.path)
                label := row.path = "" ? "SYNTHETIC WEATHER CHART  /  Try Tilt +25, then Auto Align" : row.file
                WefaxEditor(image, label, this.gui.Hwnd, 0, 0, true, true, browser.Hwnd, row.path)
                browser.Destroy()
                return
            }
            save := row.enhanced ? 0 : (adjusted) => WefaxSaveEnhanced(config, snapshot, row,
                adjusted, CleanerRequireFldigiClosed)
            label := row.file (row.enhanced ? "  /  Enhanced copy already linked" : "")
            WefaxEditor(WefaxLoad(row.path), label, this.gui.Hwnd, save, CleanerRequireFldigiClosed,
                false, true, browser.Hwnd, row.path, ObjBindMethod(this, "Scan"))
            browser.Destroy()
        } catch as problem {
            CleanerReport(problem, "Opening WEFAX image")
            status.Text := problem.Message
        }
    }

    Apply(*) {
        if this.preview
            return
        selected := Map(), at := 0
        while at := this.list.GetNext(at, "Checked") {
            row := this.rows[at]
            selected[row.id] := row.path
        }
        if !selected.Count
            return
        try {
            CleanerRequireFldigiClosed()
            if MsgBox("Remove " selected.Count " selected record(s)?`n`n" this.config.log
                . "`n`nA backup will be made first. Images will not be changed.",
                this.title, "YesNo Default2 Icon!") != "Yes"
                return
            backup := CleanerApply(this.config, this.snapshot, selected, CleanerRequireFldigiClosed)
            this.lastBackup := backup
            this.backupButton.Enabled := true
            this.Scan()
            this.status.Text := "Removed " selected.Count " record(s). Backup saved beside the logbook."
            this.caption.Value := backup
        } catch as problem {
            this.Report(problem, "Apply")
        }
    }

    OpenBackupFolder(*) {
        if this.lastBackup = ""
            return
        try {
            SplitPath(this.lastBackup, , &folder)
            Run('"' A_WinDir '\explorer.exe" "' folder '"')
        } catch as problem {
            this.Report(problem, "Opening backup folder")
        }
    }

    Report(problem, context) {
        logged := CleanerReport(problem, context)
        this.status.Text := context ": " problem.Message
            . (logged ? "" : " (Could not write Logs\Cleaner-errors.log.)")
    }
}

CleanerRequireFldigiClosed() {
    if ProcessExist("fldigi.exe")
        throw Error("Close FLdigi before applying. This utility will not close it for you.")
}
