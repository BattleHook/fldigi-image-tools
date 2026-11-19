#Requires AutoHotkey v2.0
#Include WefaxImage.ahk
#Include WefaxRecipe.ahk

WefaxSaveEnhanced(config, snapshot, row, adjusted, requireClosed) {
    requireClosed.Call()
    source := CleanerRead(config.log, true)
    logStage := "", imageStage := "", output := "", installed := false, backup := ""
    try {
        fresh := CleanerReadHandle(source)
        if !CleanerEqual(fresh, snapshot)
            throw Error("The log changed since Scan. Reopen the image browser.")
        verified := false
        for item in CleanerScan(fresh, config.rules).images {
            if item.id = row.id && item.path == row.path {
                if item.enhanced
                    throw Error("This entry already has an ENH reference. No file was overwritten.")
                row := item, verified := true
                break
            }
        }
        if !verified
            throw Error("The original image or log entry is no longer available.")
        output := CleanerEnhancedPath(row.path)
        if CleanerImageState(output) != "missing"
            throw Error("The enhanced filename is already in use or unavailable: " output)
        SplitPath(output, , &imageDir)
        SplitPath(config.log, , &logDir)
        imageStage := CleanerTemp(imageDir)
        WefaxSavePng(adjusted, imageStage)
        logStage := CleanerTemp(logDir)
        notes := row.record.spans["NOTES"], suffix := "`r`nENH:" output
        tag := RegExReplace(notes.tag, ":\d+", ":" (notes.length + StrLen(suffix)), , 1)
        ; Copy the original NOTES value as bytes, not through a string encoding conversion.
        stream := FileOpen(logStage, "w", "CP0")
        try {
            CleanerWriteRange(stream, fresh, 0, notes.start)
            stream.Write(tag)
            CleanerWriteRange(stream, fresh, notes.data, notes.length)
            stream.Write(suffix)
            CleanerWriteRange(stream, fresh, notes.end, fresh.Size - notes.end)
            if !DllCall("FlushFileBuffers", "Ptr", stream.Handle)
                throw OSError()
        } finally stream.Close()
        records := CleanerParse(CleanerRead(logStage))
        if records[row.id].fields["NOTES"] != row.record.fields["NOTES"] suffix
            throw Error("Could not verify the enhanced image reference.")
        backup := CleanerBackup(config.log, fresh, logDir)
        requireClosed.Call()
        if !DllCall("MoveFileExW", "Str", imageStage, "Str", output, "UInt", 8)
            throw OSError(A_LastError, , output)
        imageStage := "", installed := true
        CleanerReplace(logStage, config.log)
        logStage := ""
        return {image: output, backup: backup}
    } catch as problem {
        if installed
            throw Error("The enhanced PNG was saved, but the log update failed. PNG: " output
                . "; backup: " backup ". " problem.Message, -1, problem.Extra)
        throw problem
    } finally {
        DllCall("CloseHandle", "Ptr", source)
        CleanerDiscard(logStage)
        CleanerDiscard(imageStage)
    }
}

WefaxRelativePosition(parentX, parentY, childWidth, childHeight, left, top, right, bottom) {
    return {x: Max(left, Min(right - childWidth, parentX + 32)),
        y: Max(top, Min(bottom - childHeight, parentY + 40))}
}

WefaxPngExportName(sourcePath) {
    if sourcePath = ""
        return "wefax-adjusted.png"
    SplitPath(sourcePath, , , , &stem)
    return stem "_adjusted.png"
}

WefaxDialogStart(prefs, kind, filename := "") {
    folder := IniRead(prefs, "LastFolder", kind, "")
    return (folder != "" && DirExist(folder) ? RTrim(folder, "\") "\" : "") filename
}

WefaxRememberDialogFolder(prefs, kind, path) {
    SplitPath(path, , &folder)
    IniWrite(folder, prefs, "LastFolder", kind)
}

WefaxOwnerWorkArea(owner) {
    monitor := owner ? DllCall("MonitorFromWindow", "Ptr", owner, "UInt", 2, "Ptr") : 0
    bounds := Buffer(40, 0)
    NumPut("UInt", bounds.Size, bounds)
    if monitor && DllCall("GetMonitorInfoW", "Ptr", monitor, "Ptr", bounds)
        return {left: NumGet(bounds, 20, "Int"), top: NumGet(bounds, 24, "Int"),
            right: NumGet(bounds, 28, "Int"), bottom: NumGet(bounds, 32, "Int")}
    MonitorGetWorkArea(MonitorGetPrimary(), &left, &top, &right, &bottom)
    return {left: left, top: top, right: right, bottom: bottom}
}

WefaxShowRelative(gui, owner, size := "", noActivate := false) {
    if owner {
        gui.Show("Hide " size)
        WinGetPos(&x, &y, , , "ahk_id " owner)
        rect := Buffer(16)
        if !DllCall("GetWindowRect", "Ptr", gui.Hwnd, "Ptr", rect)
            throw OSError()
        width := NumGet(rect, 8, "Int") - NumGet(rect, 0, "Int")
        height := NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int")
        work := WefaxOwnerWorkArea(owner)
        position := WefaxRelativePosition(x, y, width, height, work.left, work.top, work.right, work.bottom)
        size .= " x" position.x " y" position.y
    }
    gui.Show((noActivate ? "NA " : "") size)
}

class WefaxEditor {
    __New(image, label, owner := 0, save := 0, requireClosed := 0, preview := false, show := true, opener := 0,
        sourcePath := "", refresh := 0) {
        this.image := image, this.saveAction := save
        this.refreshAction := refresh
        this.pngExportName := WefaxPngExportName(sourcePath)
        this.steps := []
        this.track := []
        this.stepRow := Min(1, image.height - 1)
        this.markStep := false
        this.zoomColumn := image.width // 2
        this.zoomGui := 0
        this.requireClosed := requireClosed
        options := "+Resize +MinSize820x430"
        if owner
            options .= " +Owner" owner
        this.gui := Gui(options, "WEFAX Post-Processing" (preview ? " - isolated preview" : ""))
        this.paneWidth := 380, this.paneHeight := 250, this.originalDirty := true
        this.gui.BackColor := "343434"
        this.gui.SetFont("s14 bold cWhite", "Segoe UI")
        this.gui.AddText("x20 y14 w780", "WEFAX POST-PROCESSING")
        this.gui.SetFont("s10 norm cFFD060", "Segoe UI")
        this.gui.AddText("x20 y46 w780 h22", label)
        this.gui.SetFont("s10 cWhite", "Segoe UI")
        this.originalLabel := this.gui.AddText("x20 y78 w380", this.ImageLabel("ORIGINAL", image))
        this.adjustedLabel := this.gui.AddText("x420 y78 w380", this.ImageLabel("ADJUSTED PREVIEW", image))
        this.original := this.gui.AddPicture("x20 y102 w380 h250")
        this.adjusted := this.gui.AddPicture("x420 y102 w380 h250")
        this.adjusted.OnEvent("Click", ObjBindMethod(this, "PickStepPoint"))
        this.gui.AddText("x20 y369 w108", "Tilt (bottom px)")
        this.tilt := this.AddAdjustment(132)
        this.gui.AddText("x306 y369 w96", "Alignment (px)")
        this.alignment := this.AddAdjustment(407)
        this.gui.AddButton("x584 y363 w116 h31", "AUTO ALIGN").OnEvent("Click", ObjBindMethod(this, "AutoAlign"))
        this.gui.AddButton("x708 y363 w92 h31", "RESET").OnEvent("Click", ObjBindMethod(this, "Reset"))
        this.gui.AddButton("x20 y406 w114 h31", "AUTO TILT").OnEvent("Click", ObjBindMethod(this, "AutoTilt"))
        this.gui.AddButton("x142 y406 w130 h31", "REPAIR STEPS").OnEvent("Click", ObjBindMethod(this, "RepairSteps"))
        this.clearStepsButton := this.gui.AddButton("x280 y406 w116 h31 Disabled", "CLEAR STEPS")
        this.clearStepsButton.OnEvent("Click", ObjBindMethod(this, "ClearSteps"))
        this.stepPicker := this.gui.AddDropDownList("x404 y407 w140")
        this.stepPicker.OnEvent("Change", ObjBindMethod(this, "SelectStep"))
        this.stepButtons := []
        for item in [{text: "Row -", x: 550, field: "row", delta: -1},
            {text: "Row +", x: 599, field: "row", delta: 1},
            {text: "Shift -", x: 648, field: "shift", delta: -1},
            {text: "Shift +", x: 697, field: "shift", delta: 1}] {
            button := this.gui.AddButton("x" item.x " y406 w46 h31 Disabled", item.text)
            button.OnEvent("Click", ObjBindMethod(this, "NudgeStep", item.field, item.delta))
            this.stepButtons.Push(button)
        }
        this.stepEnabled := this.gui.AddCheckbox("x748 y412 w60 h21 Disabled", "Apply")
        this.stepEnabled.OnEvent("Click", ObjBindMethod(this, "ToggleStep"))
        this.gui.AddText("x20 y453 w90", "Crop Top")
        this.gui.AddText("x306 y453 w96", "Crop Bottom")
        this.gui.AddText("x20 y486 w90", "Crop Left")
        this.gui.AddText("x306 y486 w96", "Crop Right")
        this.cropFields := Map()
        this.cropFields["top"] := this.AddAdjustment(132, 448, "top")
        this.cropFields["bottom"] := this.AddAdjustment(407, 448, "bottom")
        this.cropFields["left"] := this.AddAdjustment(132, 481, "left")
        this.cropFields["right"] := this.AddAdjustment(407, 481, "right")
        this.clearCropButton := this.gui.AddButton("x681 y448 w119 h31", "CLEAR CROP")
        this.clearCropButton.OnEvent("Click", ObjBindMethod(this, "ClearCrop"))
        this.gui.AddButton("x584 y481 w110 h31", "STEP ZOOM").OnEvent("Click", ObjBindMethod(this, "ShowStepZoom"))
        this.gui.AddButton("x584 y448 w90 h31", "TRACK LINE").OnEvent("Click", ObjBindMethod(this, "TrackLine"))
        this.clearTrackButton := this.gui.AddButton("x701 y481 w99 h31 Disabled", "CLEAR TRACK")
        this.clearTrackButton.OnEvent("Click", ObjBindMethod(this, "ClearTrack"))
        this.gui.SetFont("s10 cFFD060", "Segoe UI")
        this.status := this.gui.AddText("x20 y522 w780 h44",
            preview ? "ISOLATED PREVIEW - PNG and JSON exports do not change the logbook."
                : save ? "Adjust the drift and seam. Review the result before saving."
                : "This record already has an enhanced image reference. Save is disabled.")
        this.gui.SetFont("s10 cWhite", "Segoe UI")
        this.saveButton := this.gui.AddButton("x20 y572 w210 h32", "SAVE ENHANCED + LOG")
        this.saveButton.Enabled := !!save
        this.saveButton.OnEvent("Click", ObjBindMethod(this, "Save"))
        this.gui.AddButton("x240 y572 w114 h32", "SAVE PNG AS").OnEvent("Click", ObjBindMethod(this, "ExportFile", "png"))
        this.gui.AddButton("x364 y572 w112 h32", "EXPORT JSON").OnEvent("Click", ObjBindMethod(this, "ExportFile", "json"))
        this.gui.AddButton("x486 y572 w112 h32", "IMPORT JSON").OnEvent("Click", ObjBindMethod(this, "ImportRecipe"))
        this.refreshButton := this.gui.AddButton("x604 y572 w90 h32 Disabled", "Refresh List")
        this.refreshButton.OnEvent("Click", ObjBindMethod(this, "RefreshList"))
        this.closeButton := this.gui.AddButton("x700 y572 w100 h32", "CLOSE")
        this.closeButton.OnEvent("Click", ObjBindMethod(this, "Close"))
        this.footer := []
        for control in this.gui {
            control.GetPos(, &y)
            if y >= 363
                this.footer.Push({control: control, y: y})
        }
        this.gui.OnEvent("Close", ObjBindMethod(this, "Close"))
        this.gui.OnEvent("Escape", ObjBindMethod(this, "Close"))
        this.gui.OnEvent("Size", ObjBindMethod(this, "Resize"))
        this.renderTimer := ObjBindMethod(this, "Render")
        this.tilt.OnEvent("Change", ObjBindMethod(this, "Queue"))
        this.alignment.OnEvent("Change", ObjBindMethod(this, "Queue"))
        for side, field in this.cropFields
            field.OnEvent("Change", ObjBindMethod(this, "Queue"))
        this.UpdateStepControls()
        this.RenderPreview()
        if show {
            parent := opener ? opener : owner
            work := WefaxOwnerWorkArea(parent)
            scale := A_ScreenDPI / 96
            width := Max(820, Min(1400, Floor((work.right - work.left) / scale) - 48))
            height := Max(430, Min(900, Floor((work.bottom - work.top) / scale) - 70))
            this.Resize(this.gui, 0, width, height)
            this.RenderPreview()
            WefaxShowRelative(this.gui, parent, "w" width " h" height)
        }
    }

    Resize(gui, minMax, width, height) {
        if minMax = -1
            return
        paneWidth := (width - 60) // 2, paneHeight := height - 371
        if paneWidth = this.paneWidth && paneHeight = this.paneHeight
            return
        this.paneWidth := paneWidth, this.paneHeight := paneHeight
        this.adjustedLabel.Move(40 + paneWidth, , paneWidth)
        for item in this.footer
            item.control.Move(, item.y + height - 621)
        this.closeButton.Move(width - 120)
        this.status.Move(, , width - 40)
        this.originalDirty := true
        this.Queue()
    }

    AddAdjustment(x, y := 365, side := "") {
        field := this.gui.AddEdit("x" (x + 56) " y" y " w52 h27 Limit7 Center cBlack", "0")
        for button in [{label: "<<", offset: 0, step: -10}, {label: "<", offset: 28, step: -1},
            {label: ">", offset: 110, step: 1}, {label: ">>", offset: 138, step: 10}] {
            callback := side = "" ? ObjBindMethod(this, "Nudge", field, button.step)
                : ObjBindMethod(this, "NudgeCrop", side, button.step)
            this.gui.AddButton("x" (x + button.offset) " y" y " w26 h27", button.label)
                .OnEvent("Click", callback)
        }
        return field
    }

    Nudge(field, step, *) {
        if !RegExMatch(field.Value, "^-?\d+$") {
            this.status.Text := "Enter whole pixel values for Tilt and Alignment."
            return
        }
        limit := this.image.width
        before := Integer(field.Value)
        after := Max(-limit, Min(limit, before + step))
        field.Value := "" after
        this.status.Text := (field.Hwnd = this.tilt.Hwnd ? "Tilt" : "Alignment") ": " after " px."
        this.Render()
    }

    ImageLabel(title, image) => title "  /  " image.width " x " image.height " px"

    Paint(control, image, left, cropLeft := 0, cropTop := 0, markerRow := -1, markerColumn := -1) {
        ; Picture controls take ownership of the supplied HBITMAP.
        scale := A_ScreenDPI / 96
        fit := Min(this.paneWidth / this.image.width, this.paneHeight / this.image.height) * scale
        preview := WefaxPreviewBitmap(image, Max(1, Floor(image.width * fit)), Max(1, Ceil(image.height * fit)),
            markerRow, markerColumn)
        width := Max(1, Round(preview.width / scale)), height := Max(1, Round(preview.height / scale))
        fullHeight := Round(this.image.height * fit / scale)
        fullWidth := Round(this.image.width * fit / scale)
        control.Value := "HBITMAP:" preview.handle
        control.Move(left + (this.paneWidth - fullWidth) // 2 + Round(cropLeft * fit / scale),
            102 + (this.paneHeight - fullHeight) // 2 + Round(cropTop * fit / scale), width, height)
    }

    Values() {
        tilt := this.tilt.Value, alignment := this.alignment.Value
        if !RegExMatch(tilt, "^-?\d+$") || !RegExMatch(alignment, "^-?\d+$")
            throw ValueError("Enter whole pixel values for Tilt and Alignment.")
        if Abs(Integer(tilt)) > this.image.width || Abs(Integer(alignment)) > this.image.width
            throw ValueError("Tilt and Alignment must be within ±" this.image.width " pixels.")
        return {tilt: Integer(tilt), alignment: Integer(alignment)}
    }

    Queue(*) => SetTimer(this.renderTimer, -160)

    Render(*) {
        try {
            this.RenderPreview()
            if this.status.Text ~= "^Enter whole|^Tilt and Alignment|^Crop "
                this.status.Text := "Review the adjusted preview."
        } catch ValueError as problem {
            this.status.Text := problem.Message
        } catch as problem {
            this.Report(problem, "Preview")
        }
    }

    RenderPreview() {
        if this.originalDirty {
            this.Paint(this.original, this.image, 20)
            this.originalDirty := false
        }
        values := this.Values()
        crop := this.CropValues()
        image := this.AdjustedImage(values, crop)
        marker := this.markStep ? this.stepRow - crop.top : -1
        column := this.zoomGui ? this.zoomColumn - crop.left : -1
        this.Paint(this.adjusted, image, 40 + this.paneWidth, crop.left, crop.top, marker, column)
        this.displayedCrop := crop
        this.displayedWidth := image.width
        this.displayedHeight := image.height
        if this.zoomGui
            this.RenderStepZoom(image, crop)
        this.adjustedLabel.Text := this.ImageLabel("ADJUSTED PREVIEW", image)
        DllCall("RedrawWindow", "Ptr", this.gui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
    }

    AdjustedImage(values, crop := unset) {
        if !IsSet(crop)
            crop := this.CropValues()
        return WefaxTransform(this.image, values.tilt, values.alignment, this.ActiveSteps(), crop, this.track)
    }

    CropAmount(side) {
        text := this.cropFields[side].Value
        if !RegExMatch(text, "^\d+$")
            throw ValueError("Crop values must be nonnegative whole pixels.")
        return Integer(text)
    }

    CropValues() {
        return {top: this.CropAmount("top"), bottom: this.CropAmount("bottom"),
            left: this.CropAmount("left"), right: this.CropAmount("right")}
    }

    NudgeCrop(side, step, *) {
        try {
            opposite := Map("top", "bottom", "bottom", "top", "left", "right", "right", "left")[side]
            dimension := side = "left" || side = "right" ? this.image.width : this.image.height
            limit := dimension - 1 - this.CropAmount(opposite)
            if limit < 0
                throw ValueError("Crop must leave at least one row and one column.")
            this.cropFields[side].Value := "" Max(0, Min(limit, this.CropAmount(side) + step))
            this.Render()
        } catch ValueError as problem {
            this.status.Text := problem.Message
        }
    }

    ClearCrop(*) {
        for side, field in this.cropFields
            field.Value := "0"
        this.status.Text := "Crop cleared. Other corrections are unchanged."
        this.Render()
    }

    Reset(*) {
        this.tilt.Value := "0", this.alignment.Value := "0"
        this.steps := []
        this.track := []
        this.clearTrackButton.Enabled := false
        this.markStep := false
        this.UpdateStepControls()
        this.ClearCrop()
        this.status.Text := "Adjustments reset."
    }

    TrackLine(*) {
        if !this.markStep {
            this.status.Text := "Click a clear vertical feature in the adjusted image first."
            return
        }
        try {
            values := this.Values()
            base := WefaxTransform(this.image, values.tilt, values.alignment, this.ActiveSteps())
            column := WefaxWrap(this.zoomColumn + (this.track.Length ? this.track[this.stepRow + 1] : 0),
                this.image.width)
            result := WefaxTrackLine(base, this.stepRow, column)
            if !result.found {
                this.status.Text := "No confident line correction found. Existing adjustments kept."
                return
            }
            this.track := result.offsets
            this.zoomColumn := column
            this.clearTrackButton.Enabled := true
            this.status.Text := "Tracked rows " (result.first + 1) "–" (result.last + 1) " of " this.image.height
                . "; " result.jumps " abrupt change(s). Review the preview or choose Clear Track."
            this.Render()
        } catch ValueError as problem {
            this.status.Text := problem.Message
        } catch as problem {
            this.Report(problem, "Track Line")
        }
    }

    ClearTrack(*) {
        this.track := []
        this.clearTrackButton.Enabled := false
        this.status.Text := "Line tracking cleared. Manual adjustments kept."
        this.Render()
    }

    AutoTilt(*) {
        try {
            values := this.Values()
            image := this.StepCorrectedImage()
            result := WefaxAutoTilt(image, values.tilt)
            if !result.found {
                this.status.Text := "No clear tilt improvement found. Tilt kept at " values.tilt " px."
                return
            }
            this.tilt.Value := "" result.tilt
            this.status.Text := "Suggested tilt: " result.tilt " px. Review the adjusted preview."
            this.Render()
        } catch ValueError as problem {
            this.status.Text := problem.Message
        } catch as problem {
            this.Report(problem, "Auto Tilt")
        }
    }

    RepairSteps(*) {
        try {
            values := this.Values()
            steps := WefaxRepairSteps(this.image, values.tilt)
            if !steps.Length {
                this.status.Text := "No confident sideways steps found. Preview unchanged."
                return
            }
            this.steps := steps
            this.stepRow := steps[1].row
            this.markStep := true
            this.UpdateStepControls()
            this.status.Text := "Detected " steps.Length " candidate jumps. Select one to mark and fine-tune it."
            this.Render()
        } catch ValueError as problem {
            this.status.Text := problem.Message
        } catch as problem {
            this.Report(problem, "Repair Steps")
        }
    }

    ClearSteps(*) {
        this.steps := []
        this.markStep := false
        this.UpdateStepControls()
        this.status.Text := "Step repairs cleared. Tilt and Alignment are unchanged."
        this.Render()
    }

    ActiveSteps() {
        active := []
        for step in this.steps
            if !step.HasOwnProp("enabled") || step.enabled
                active.Push(step)
        return active
    }

    StepCorrectedImage() {
        active := this.ActiveSteps()
        return active.Length ? WefaxTransform(this.image, 0, 0, active) : this.image
    }

    StepIndex() {
        for index, step in this.steps
            if step.row = this.stepRow
                return index
        return 0
    }

    UpdateStepControls() {
        index := this.StepIndex()
        labels := [index ? "Select a correction" : "Row " (this.stepRow + 1) " / 0 px"]
        for step in this.steps
            labels.Push("Row " (step.row + 1) " / " Format("{:+}", -step.shift) " px")
        this.stepPicker.Delete()
        this.stepPicker.Add(labels)
        this.stepPicker.Choose(index + 1)
        this.clearStepsButton.Enabled := this.steps.Length > 0
        this.SyncStepControls()
    }

    SyncStepControls() {
        index := this.StepIndex()
        available := this.steps.Has(index)
        this.stepEnabled.Enabled := available
        this.stepEnabled.Value := available && (!this.steps[index].HasOwnProp("enabled") || this.steps[index].enabled)
        for button in this.stepButtons
            button.Enabled := this.image.height > 1
    }

    SelectStep(*) {
        index := this.stepPicker.Value - 1
        if this.steps.Has(index)
            this.stepRow := this.steps[index].row
        this.markStep := true
        this.UpdateStepControls()
        this.Render()
    }

    NudgeStep(field, delta, *) {
        if this.image.height < 2
            return
        this.markStep := true
        if field = "row" {
            this.stepRow := Max(0, Min(this.image.height - 1, this.stepRow + delta))
        } else {
            index := this.StepIndex()
            shift := index ? this.steps[index].shift : 0
            shift := Max(-this.image.width, Min(this.image.width, shift - delta))
            if index {
                if shift
                    this.steps[index].shift := shift
                else
                    this.steps.RemoveAt(index)
            } else if shift {
                at := 1
                while at <= this.steps.Length && this.steps[at].row < this.stepRow
                    at++
                this.steps.InsertAt(at, {row: this.stepRow, shift: shift})
            }
        }
        this.UpdateStepControls()
        this.Render()
    }

    ToggleStep(*) {
        index := this.StepIndex()
        if this.steps.Has(index) {
            this.steps[index].enabled := this.stepEnabled.Value
            this.Render()
        }
    }

    PickStepPoint(*) {
        if !HasProp(this, "displayedCrop")
            return
        point := this.PictureClick(this.adjusted)
        if point && this.SelectPreviewPoint(point.x, point.y, point.width, point.height)
            this.ShowStepZoom()
    }

    PictureClick(control) {
        point := Buffer(8)
        rect := Buffer(16)
        if !DllCall("GetCursorPos", "Ptr", point)
            || !DllCall("ScreenToClient", "Ptr", control.Hwnd, "Ptr", point)
            || !DllCall("GetClientRect", "Ptr", control.Hwnd, "Ptr", rect) {
            this.Report(OSError(), "Locating zoom point")
            return 0
        }
        return {x: NumGet(point, 0, "Int"), y: NumGet(point, 4, "Int"),
            width: NumGet(rect, 8, "Int"), height: NumGet(rect, 12, "Int")}
    }

    SelectPreviewPoint(x, y, width, height) {
        if x < 0 || y < 0 || x >= width || y >= height
            return false
        this.SetStepPoint(this.displayedCrop.top + y * this.displayedHeight // height,
            this.displayedCrop.left + x * this.displayedWidth // width)
        return true
    }

    SetStepPoint(row, column) {
        this.stepRow := row
        this.zoomColumn := column
        this.markStep := true
        this.UpdateStepControls()
    }

    ShowStepZoom(*) {
        opening := !this.zoomGui
        if opening {
            this.zoomGui := Gui("+Owner" this.gui.Hwnd, "WEFAX Step Zoom")
            this.zoomGui.BackColor := "343434"
            this.zoomGui.SetFont("s10 cWhite", "Segoe UI")
            this.zoomStatus := this.zoomGui.AddText("x12 y12 w480 h40", "")
            this.zoomPicture := this.zoomGui.AddPicture("x12 y58 w480 h256")
            this.zoomPicture.OnEvent("Click", ObjBindMethod(this, "PickZoomPoint"))
            this.zoomGui.OnEvent("Close", ObjBindMethod(this, "CloseStepZoom"))
            this.zoomGui.OnEvent("Escape", ObjBindMethod(this, "CloseStepZoom"))
        }
        this.markStep := true
        this.Render()
        if opening
            WefaxShowRelative(this.zoomGui, this.gui.Hwnd, "w504 h326", true)
    }

    PickZoomPoint(*) {
        if !HasProp(this, "zoomBounds")
            return
        point := this.PictureClick(this.zoomPicture)
        if point && this.SelectZoomPoint(point)
            this.Render()
    }

    SelectZoomPoint(point) {
        if point.x < 0 || point.y < 0 || point.x >= point.width || point.y >= point.height
            return false
        bounds := this.zoomBounds
        this.SetStepPoint(bounds.top + point.y * bounds.height // point.height,
            bounds.left + point.x * bounds.width // point.width)
        return true
    }

    RenderStepZoom(image, crop) {
        region := WefaxZoomRegion(image, this.stepRow - crop.top, this.zoomColumn - crop.left)
        scale := A_ScreenDPI / 96
        bitmap := WefaxPreviewBitmap(region.image, Floor(480 * scale), Floor(256 * scale),
            region.row, region.column, true)
        this.zoomPicture.Value := "HBITMAP:" bitmap.handle
        this.zoomPicture.Move(12, 58, Max(1, Round(bitmap.width / scale)), Max(1, Round(bitmap.height / scale)))
        this.zoomBounds := {top: crop.top + region.top, left: crop.left + region.left,
            width: region.image.width, height: region.image.height}
        this.zoomStatus.Text := "Row " (this.stepRow + 1) " | Column " (this.zoomColumn + 1)
            . (region.row < 0 || region.column < 0 ? " (guide outside crop)" : "")
            . "`nClick either preview to select a row and column."
    }

    CloseStepZoom(*) {
        this.zoomGui.Destroy()
        this.zoomGui := 0
        this.Render()
    }

    AutoAlign(*) {
        try {
            values := this.Values()
            image := this.StepCorrectedImage()
            result := WefaxAutoAlign(image, values.tilt, values.alignment)
            if !result.found {
                this.status.Text := "No clearly better seam found. Alignment kept at " values.alignment " px."
                return
            }
            this.alignment.Value := "" result.offset
            this.status.Text := "Suggested alignment: " result.offset " px. Review the seam before saving."
            this.Render()
        } catch ValueError as problem {
            this.status.Text := problem.Message
        } catch as problem {
            this.Report(problem, "Auto Align")
        }
    }

    RecipeText() {
        values := this.Values(), crop := this.CropValues()
        if crop.top + crop.bottom >= this.image.height || crop.left + crop.right >= this.image.width
            throw ValueError("Crop must leave at least one row and one column.")
        return WefaxRecipeText(this.image, values, crop, this.steps, this.track,
            this.stepRow, this.zoomColumn, this.markStep)
    }

    ApplyRecipe(recipe) {
        this.tilt.Value := "" recipe.values.tilt
        this.alignment.Value := "" recipe.values.alignment
        for side, field in this.cropFields
            field.Value := "" recipe.crop.%side%
        this.steps := recipe.steps
        this.track := recipe.track
        this.stepRow := recipe.row
        this.zoomColumn := recipe.column
        this.markStep := recipe.marked
        this.clearTrackButton.Enabled := this.track.Length > 0
        this.UpdateStepControls()
        this.RenderPreview()
    }

    ExportFile(ext, *) {
        try {
            if ext = "png" {
                writer := WefaxSavePng.Bind(this.AdjustedImage(this.Values()))
                label := "PNG image (*.png)"
                suggestedName := this.pngExportName
            } else {
                writer := WefaxWriteRecipeText.Bind(this.RecipeText())
                label := "JSON recipe (*.json)"
                suggestedName := "wefax-adjusted.json"
            }
            this.gui.Opt("+OwnDialogs")
            path := FileSelect("S", WefaxDialogStart(this.DialogPrefs(), ext, suggestedName),
                "Save adjusted " StrUpper(ext) " as", label)
            if !path
                return
            SplitPath(path, , , &chosenExt)
            if !chosenExt
                path .= "." ext
            else if chosenExt != ext
                throw ValueError("Choose a ." ext " filename.")
            WefaxWriteNew(path, writer)
            this.status.Text := "Saved " StrUpper(ext) ": " path
            this.RememberFolder(ext, path)
        } catch ValueError as problem {
            this.status.Text := problem.Message
        } catch as problem {
            this.Report(problem, "Export " StrUpper(ext))
        }
    }

    ImportRecipe(*) {
        try {
            this.gui.Opt("+OwnDialogs")
            path := FileSelect(3, WefaxDialogStart(this.DialogPrefs(), "json"),
                "Import WEFAX post-processing recipe", "JSON recipe (*.json)")
            if !path
                return
            recipe := WefaxReadRecipe(path, this.image)
            if MsgBox("Replace the current post-processing settings with this recipe?",
                "WEFAX Post-Processing", "YesNo Default2 Owner" this.gui.Hwnd) != "Yes"
                return
            this.ApplyRecipe(recipe)
            this.status.Text := "Recipe imported. Review the adjusted preview before saving."
            this.RememberFolder("json", path)
        } catch ValueError as problem {
            this.status.Text := problem.Message
        } catch as problem {
            this.Report(problem, "Import JSON")
        }
    }

    DialogPrefs() => A_ScriptDir "\Cleaner-preferences.ini"

    RememberFolder(kind, path) {
        try WefaxRememberDialogFolder(this.DialogPrefs(), kind, path)
        catch as problem {
            CleanerReport(problem, "Remembering " StrUpper(kind) " dialog folder")
            this.status.Text .= "`nCould not remember the folder: " problem.Message
        }
    }

    Save(*) {
        if !this.saveAction
            return
        try {
            values := this.Values()
            this.requireClosed.Call()
            if MsgBox("Save a new _enh PNG and add an ENH: line to this entry?`n"
                . "The original image stays unchanged. A logbook backup is made first.",
                "WEFAX Post-Processing", "YesNo Default2 Icon! Owner" this.gui.Hwnd) != "Yes"
                return
            this.SaveEnhancement(this.AdjustedImage(values))
        } catch ValueError as problem {
            this.status.Text := problem.Message
        } catch as problem {
            this.Report(problem, "Save enhancement")
        }
    }

    SaveEnhancement(adjusted) {
        saved := this.saveAction.Call(adjusted)
        this.saveAction := 0
        this.saveButton.Enabled := false
        this.refreshButton.Enabled := !!this.refreshAction
        this.status.Text := "Saved enhanced PNG and updated NOTES. ADIF backup saved beside the logbook."
            . (this.refreshAction ? "`nUse Refresh List to rescan cleanup candidates in the main window." : "")
        return saved
    }

    RefreshList(*) {
        if !this.refreshButton.Enabled
            return
        try {
            this.status.Text := this.refreshAction.Call()
                ? "Cleanup list refreshed in the main window."
                : "Enhancement saved, but the list could not be refreshed. See the main window for the scan error."
        } catch as problem {
            this.Report(problem, "Refresh List")
        }
    }

    Report(problem, context) {
        logged := CleanerReport(problem, context)
        this.status.Text := context ": " problem.Message (logged ? "" : " (Diagnostic log unavailable.)")
    }

    Close(*) {
        SetTimer(this.renderTimer, 0)
        if this.zoomGui
            this.zoomGui.Destroy()
        this.gui.Destroy()
    }
}
