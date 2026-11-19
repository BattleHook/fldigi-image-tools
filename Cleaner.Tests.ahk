#Requires AutoHotkey v2.0
#ErrorStdOut
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
#Include CleanerCore.ahk
#Include WefaxEditor.ahk

OnError((problem, mode) => TestAbort(problem, mode))
root := A_ScriptDir "\.test-" DllCall("GetCurrentProcessId", "UInt")
if FileExist(root)
    throw Error("Test directory already exists: " root)
DirCreate(root)
exitCode := 0
try {
    images := root "\WEFAX", fixtureLog := root "\fixture.adi", ini := root "\fixture.ini"
    DirCreate(images)
    FileAppend("fixture", images "\kept.png")
    FileAppend("[Logbook]`r`nPath=" fixtureLog "`r`n[Rule WEFAX]`r`nEnabled=1`r`nMode=FAX`r`nFolder="
        images "`r`nField=NOTES`r`nPrefix=RX:`r`nExtensions=png`r`n", ini, "UTF-16")
    config := CleanerConfig(ini)
    preamble := "File: fixture.adi`r`n"
    header := "<ADIF_VER:5>2.2.7`r`n<PROGRAMID:6>fldigi<EOH>`r`n"
    qso := Record("RTTY", "Line one`nLiteral <EOR> inside notes: " Chr(233))
    missing := Record("FAX", "RX:missing.png")
    absolute := Record("FAX", "RX:" images "\gone image.png")
    kept := Record("FAX", "RX:kept.png")
    multiple := Record("FAX", "RX:missing.png`nRX:kept.png")
    unrelated := Record("PSK", "RX:missing.png")
    outside := Record("FAX", "RX:" root "\outside.png")
    before := preamble header qso missing absolute kept multiple unrelated outside
    expected := preamble header qso "`r`n" absolute kept multiple unrelated outside
    WriteText(fixtureLog, Chr(0xFEFF) "File: fixture.adi`n`n" header qso)
    Check(CleanerParse(CleanerRead(fixtureLog)).Length = 1, "FLdigi preamble with UTF-8 BOM and LF")
    WriteText(fixtureLog, "Unexpected text`r`n" header qso)
    RequireError(() => CleanerParse(CleanerRead(fixtureLog)), "Unexpected ADIF data at byte 0")
    WriteText(fixtureLog, header qso preamble header missing)
    RequireError(() => CleanerParse(CleanerRead(fixtureLog)), "Unexpected ADIF data at byte")
    WriteText(fixtureLog, before)
    snapshot := CleanerRead(fixtureLog)
    scan := CleanerScan(snapshot, config.rules)
    Check(scan.total = 7 && scan.candidates.Length = 2 && scan.skipped = 2, "scan classification")
    Check(scan.candidates[1].path = images "\missing.png" && scan.candidates[2].path = images "\gone image.png",
        "relative and absolute path resolution")
    selected := Map(scan.candidates[1].id, scan.candidates[1].path)
    RequireError(() => CleanerApply(config, snapshot, selected, ClosedBlocked), "simulated FLdigi process")
    FileAppend("restored", images "\missing.png")
    RequireError(() => CleanerApply(config, snapshot, selected, (*) => true), "cannot be verified")
    FileDelete(images "\missing.png")
    WriteText(fixtureLog, before "`r`n")
    RequireError(() => CleanerApply(config, snapshot, selected, (*) => true), "changed since Scan")
    DirMove(images, images "-offline")
    scanWhileOffline := CleanerScan(snapshot, config.rules)
    Check(!scanWhileOffline.candidates.Length && scanWhileOffline.missingFolders.Count = 1, "unavailable root")
    DirMove(images "-offline", images)
    WriteText(fixtureLog, before "<NOTES:12>short")
    RequireError(() => CleanerScan(CleanerRead(fixtureLog), config.rules), "Truncated")
    WriteText(fixtureLog, before)
    backup := CleanerApply(config, snapshot, selected, (*) => true)
    Check(CleanerEqual(CleanerRead(backup), snapshot), "backup is byte identical")
    FileAppend(expected, root "\expected.adi", "UTF-8-RAW")
    Check(CleanerEqual(CleanerRead(root "\expected.adi"), CleanerRead(fixtureLog)),
        "only checked record removed; preamble and all retained bytes are unchanged")
    Check(FileExist(images "\kept.png"), "image was not touched")
    TestWefax(config, images, root)
    TestWefaxDialogFolders(root, images)
    if A_Args.Length && A_Args[1] != "--simulate-cleanup-failure"
        TestCopiedWefax(A_Args[1])
    if A_Args.Length && A_Args[1] = "--simulate-cleanup-failure" {
        if TestCleanup(DirDelete, root)
            throw Error("Expected cleanup of a nonempty directory to fail.")
        exitCode := 1
    }
} catch as problem {
    TestReport(problem, "test")
    exitCode := 1
} finally {
    Loop Files fixtureLog ".*.bak", "F"
        if !TestCleanup(FileDelete, A_LoopFileFullPath)
            exitCode := 1
    for fixture in [fixtureLog, ini, root "\expected.adi", root "\recipe.json", root "\adjusted.png", root "\preferences.ini",
        images "\kept.png", images "\missing.png", images "-offline\kept.png",
        images "\weather.png", images "\weather_enh.png", images "\weather-recycled.fixture"] {
        if FileExist(fixture) && !TestCleanup(FileDelete, fixture)
            exitCode := 1
    }
    for folder in [images, images "-offline", root] {
        if DirExist(folder) && !TestCleanup(DirDelete, folder)
            exitCode := 1
    }
}
if !exitCode
    FileAppend("PASS: cleanup regressions, Auto Align and tilt, PNG/JSON export, and byte-exact ADIF update and backup.`n", "*")
ExitApp(exitCode)

TestWefax(config, images, root) {
    image := WefaxDemo()
    TestWefaxTrack()
    position := WefaxRelativePosition(-400, 900, 504, 326, -1920, 0, 0, 1040)
    Check(position.x = -504 && position.y = 714, "child placement clamps to the opener's monitor work area")
    tiltResult := WefaxAutoTilt(image, 0)
    Check(tiltResult.found && Abs(tiltResult.tilt - 25) <= 3, "Auto Tilt estimates known steady drift")
    Check(!WefaxAutoTilt(image, 25).found, "Auto Tilt keeps an already corrected tilt")
    TestWefaxSteps()
    strip := {width: 4, height: 1, pixels: Buffer(16, 0)}
    NumPut("UInt", 0xFFFFFFFF, strip.pixels, 0)
    Check(NumGet(WefaxTransform(strip, 0, -1).pixels, 12, "UInt") = 0xFFFFFFFF,
        "negative alignment moves the leftmost pixel left and wraps it to the right edge")
    Check(NumGet(WefaxTransform(strip, 0, 1).pixels, 4, "UInt") = 0xFFFFFFFF,
        "positive alignment moves the leftmost pixel one position right")
    editor := WefaxEditor(image, "Synthetic editor test", 0, 0, 0, true, false)
    try {
        Check(!editor.saveButton.Enabled, "isolated editor opens with saving disabled")
        for field in [editor.tilt, editor.alignment, editor.cropFields["top"], editor.cropFields["bottom"],
            editor.cropFields["left"], editor.cropFields["right"]]
            Check((ControlGetStyle(field) & 3) = 1, "each numeric editor field is centered")
        editor.original.GetPos(, , &originalWidth)
        editor.Resize(editor.gui, 0, 1300, 850)
        editor.RenderPreview()
        editor.original.GetPos(, , &expandedWidth)
        editor.adjusted.GetPos(, &pictureTop, &adjustedWidth, &pictureHeight)
        editor.tilt.GetPos(, &tiltTop)
        Check(expandedWidth > originalWidth * 1.5 && expandedWidth = adjustedWidth
            && pictureTop + pictureHeight < tiltTop, "both previews grow without covering controls")
        editor.Resize(editor.gui, 0, 820, 430)
        editor.RenderPreview()
        editor.closeButton.GetPos(&closeX, &closeY, &closeWidth, &closeHeight)
        Check(closeX + closeWidth <= 820 && closeY + closeHeight <= 430,
            "Close remains inside the compact client area after resizing")
        editor.tilt.Value := "25"
        editor.AutoAlign()
        Check(Abs(Integer(editor.alignment.Value) + 117) <= 3
            && InStr(editor.status.Text, "Suggested alignment:"), "editor previews an Auto Align suggestion")
        aligned := Integer(editor.alignment.Value)
        editor.AutoAlign()
        Check(Integer(editor.alignment.Value) = aligned && InStr(editor.status.Text, "Alignment kept"),
            "Auto Align retains an already corrected nonzero alignment")
        editor.Nudge(editor.tilt, -1)
        editor.Nudge(editor.tilt, 10)
        Check(editor.tilt.Value = 34 && editor.alignment.Value = aligned, "fine and coarse tilt steps leave alignment unchanged")
        editor.alignment.Value := "" (image.width - 1)
        editor.Nudge(editor.alignment, 10)
        Check(editor.alignment.Value = image.width && editor.tilt.Value = 34, "alignment clamps at the image width")
        editor.Nudge(editor.alignment, -1)
        Check(editor.alignment.Value = image.width - 1, "fine alignment step moves away from the limit")
        editor.steps := [{row: 40, shift: 3}]
        editor.stepRow := 40
        editor.UpdateStepControls()
        Check(InStr(editor.stepPicker.Text, "Row 41 / -3 px"), "step picker shows source row and visible shift")
        editor.NudgeStep("row", 1)
        Check(editor.steps.Length = 1 && editor.steps[1].row = 40 && editor.steps[1].shift = 3
            && editor.stepPicker.Text = "Row 42 / 0 px", "navigation preserves the old correction and selects an unedited row")
        editor.NudgeStep("shift", 1)
        Check(editor.ActiveSteps().Length = 2 && editor.ActiveSteps()[2].row = 41 && editor.ActiveSteps()[2].shift = -1,
            "a nonzero manual shift adds a separate correction")
        editor.NudgeStep("row", -1)
        Check(editor.stepPicker.Text = "Row 41 / -3 px", "returning to a corrected row restores its own value")
        editor.NudgeStep("row", 1)
        editor.stepEnabled.Value := 0
        editor.ToggleStep()
        Check(editor.ActiveSteps().Length = 1 && editor.steps.Length = 2,
            "disabling a candidate excludes it without deleting it")
        editor.stepEnabled.Value := 1
        editor.ToggleStep()
        Check(editor.ActiveSteps().Length = 2, "candidate can be reapplied")
        editor.NudgeStep("shift", -1)
        Check(editor.steps.Length = 1 && editor.stepPicker.Text = "Row 42 / 0 px",
            "returning the manual correction to zero removes its list entry")
        values := editor.Values()
        full := editor.AdjustedImage(values)
        editor.NudgeCrop("top", 10)
        editor.NudgeCrop("top", -1)
        editor.cropFields["bottom"].Value := "11"
        editor.cropFields["left"].Value := "7"
        editor.cropFields["right"].Value := "13"
        cropped := editor.AdjustedImage(values)
        zoom := WefaxZoomRegion(cropped, 41 - 9, 97 - 7)
        Check(zoom.row = 32 && zoom.column = 60
            && NumGet(zoom.image.pixels, (zoom.row * 120 + zoom.column) * 4, "UInt")
                = NumGet(cropped.pixels, (32 * cropped.width + 90) * 4, "UInt"),
            "zoom crosshair maps to the selected source row and column after cropping")
        Check(WefaxZoomRegion(cropped, -1, cropped.width).column = -1,
            "a column outside the crop is not marked")
        editor.RenderPreview()
        Check(editor.SelectPreviewPoint(45, 16, 170, 120)
            && editor.stepRow = 41 && editor.zoomColumn = 97
            && editor.stepPicker.Text = "Row 42 / 0 px"
            && editor.steps.Length = 1 && editor.steps[1].row = 40 && editor.steps[1].shift = 3,
            "clicking a scaled, cropped preview selects both coordinates without editing corrections")
        Check(!editor.SelectPreviewPoint(170, 16, 170, 120) && editor.stepRow = 41 && editor.zoomColumn = 97,
            "clicks outside the rendered picture leave the selection unchanged")
        editor.zoomBounds := {top: 20, left: 30, width: 120, height: 64}
        Check(editor.SelectZoomPoint({x: 40, y: 80, width: 480, height: 256})
            && editor.stepRow = 40 && editor.zoomColumn = 40
            && editor.stepPicker.Text = "Row 41 / -3 px" && editor.steps.Length = 1,
            "clicking the zoom selects an existing row and column without changing the shift")
        Check(InStr(editor.originalLabel.Text, "360 x 260 px") && InStr(editor.adjustedLabel.Text, "340 x 240 px"),
            "preview labels show original and cropped output dimensions")
        Check(cropped.width = image.width - 20 && cropped.height = image.height - 20,
            "four-sided crop produces the expected dimensions")
        Loop cropped.height {
            offset := (A_Index - 1) * cropped.width * 4
            expected := ((A_Index - 1 + 9) * full.width + 7) * 4
            Check(DllCall("ntdll\RtlCompareMemory", "Ptr", cropped.pixels.Ptr + offset,
                "Ptr", full.pixels.Ptr + expected, "UPtr", cropped.width * 4, "UPtr") = cropped.width * 4,
                "cropped rows match the same region of the full corrected image")
        }
        editor.cropFields["right"].Value := "" (image.width - 7)
        RequireError(() => editor.AdjustedImage(values), "leave at least one row and one column")
        editor.NudgeCrop("right", 10)
        Check(editor.AdjustedImage(values).width = 1, "crop arrow clamps at one remaining column")
        editor.ClearCrop()
        Check(CleanerEqual(editor.AdjustedImage(values).pixels, full.pixels),
            "Clear Crop restores the adjusted image without clearing other corrections")
    } finally editor.Close()
    suggestion := WefaxAutoAlign(image, 25)
    Check(suggestion.found && Abs(suggestion.offset + 117) <= 3, "Auto Align suggests a leftward shift for a known seam")
    blank := {width: 40, height: 40, pixels: Buffer(40 * 40 * 4, 255)}
    Check(!WefaxAutoAlign(blank, 0).found, "Auto Align does not guess on a blank image")
    source := images "\weather.png", target := images "\weather_enh.png"
    WefaxSavePng(image, source)
    original := CleanerRead(source)
    adjusted := WefaxTransform(WefaxLoad(source), 25, suggestion.offset, [], {top: 2, bottom: 18, left: 0, right: 3})
    Check(WefaxLight(adjusted, 0, 0) < 30 && WefaxLight(adjusted, 0, adjusted.height - 1) < 30,
        "Tilt and Alignment straighten and position the seam")
    intro := "<ADIF_VER:5>2.2.7<EOH>`r`n"
    weather := Record("FAX", "RX:weather.png"), ordinary := Record("RTTY", "Unchanged <EOR> notes")
    WriteText(config.log, intro weather ordinary)
    snapshot := CleanerRead(config.log)
    weatherRow := CleanerScan(snapshot, config.rules).images[1]
    TestWefaxRecipe(root, source, config.log, original, snapshot)
    RequireError(() => WefaxSaveEnhanced(config, snapshot, weatherRow, adjusted, ClosedBlocked), "simulated FLdigi process")
    FileAppend("collision", target)
    RequireError(() => WefaxSaveEnhanced(config, snapshot, weatherRow, adjusted, (*) => true), "already in use")
    FileDelete(target)
    WriteText(config.log, intro weather ordinary "`r`n")
    RequireError(() => WefaxSaveEnhanced(config, snapshot, weatherRow, adjusted, (*) => true), "changed since Scan")
    WriteText(config.log, intro weather ordinary)
    refreshCount := 0
    refresh := () => (++refreshCount, CleanerScan(CleanerRead(config.log), config.rules).images[1].enhanced = target)
    save := (output) => WefaxSaveEnhanced(config, snapshot, weatherRow, output, (*) => true)
    editor := WefaxEditor(image, "Refresh List test", 0, save, (*) => true, false, false, 0, source, refresh)
    try {
        editor.RefreshList()
        Check(!editor.refreshButton.Enabled && refreshCount = 0, "refresh is unavailable before saving")
        FileAppend("collision", target)
        RequireError(() => editor.SaveEnhancement(adjusted), "already in use")
        Check(!editor.refreshButton.Enabled && refreshCount = 0, "a failed save does not enable refresh")
        FileDelete(target)
        saved := editor.SaveEnhancement(adjusted)
        Check(editor.refreshButton.Enabled && refreshCount = 0, "saving enables optional refresh without triggering it")
        afterSave := CleanerRead(config.log)
        editor.RefreshList()
        Check(refreshCount = 1 && editor.status.Text = "Cleanup list refreshed in the main window."
            && CleanerEqual(CleanerRead(config.log), afterSave), "manual refresh sees the new link without writing to the log")
    } finally editor.Close()
    Check(saved.image = target && CleanerEqual(CleanerRead(source), original), "output name and original image preservation")
    Check(CleanerEqual(CleanerRead(saved.backup), snapshot), "enhancement ADIF backup is byte identical")
    savedImage := WefaxLoad(target)
    Check(savedImage.width = image.width - 3 && savedImage.height = image.height - 20
        && CleanerEqual(savedImage.pixels, adjusted.pixels), "saved PNG has the selected crop at original resolution")
    WriteText(root "\expected.adi", intro Record("FAX", "RX:weather.png`r`nENH:" target) ordinary)
    updated := CleanerRead(config.log)
    Check(CleanerEqual(updated, CleanerRead(root "\expected.adi")), "only the selected NOTES field changed")
    row := CleanerScan(updated, config.rules).images[1]
    moved := images "\weather-recycled.fixture"
    moveOriginal := (path) => FileMove(path, moved)
    RequireError(() => CleanerRecycleOriginal(config, updated, row, ClosedBlocked, moveOriginal), "simulated FLdigi process")
    RequireError(() => CleanerRecycleOriginal(config, snapshot, row, (*) => true, moveOriginal), "log changed")
    RequireError(() => CleanerRecycleOriginal(config, updated, row, (*) => true, (*) => 0), "did not move")
    CleanerRecycleOriginal(config, updated, row, (*) => true, moveOriginal)
    Check(CleanerEqual(CleanerRead(moved), original) && CleanerEqual(CleanerRead(config.log), updated)
        && CleanerEqual(WefaxLoad(target).pixels, adjusted.pixels), "only the selected original was moved")
    Check(!CleanerScan(updated, config.rules).candidates.Length, "enhanced image alone protects the log entry")
    FileDelete(target)
    Check(CleanerScan(updated, config.rules).candidates.Length = 1, "both missing images qualify for cleanup")
}

TestWefaxRecipe(root, source, log, original, snapshot) {
    image := WefaxLoad(source)
    editor := WefaxEditor(image, "Recipe test", 0, 0, 0, true, false)
    try {
        editor.tilt.Value := "-12", editor.alignment.Value := "6"
        editor.cropFields["top"].Value := "2", editor.cropFields["bottom"].Value := "3"
        editor.cropFields["left"].Value := "4", editor.cropFields["right"].Value := "5"
        editor.steps := [{row: 10, shift: -4}, {row: 25, shift: 2, enabled: 0}]
        Loop image.height
            editor.track.Push(A_Index // 9)
        editor.SetStepPoint(25, 40)
        expected := editor.AdjustedImage(editor.Values())
        text := editor.RecipeText()
        json := root "\recipe.json", png := root "\adjusted.png"
        WefaxWriteNew(json, WefaxWriteRecipeText.Bind(text))
        editor.Reset()
        editor.ApplyRecipe(WefaxReadRecipe(json, image))
        Check(editor.stepRow = 25 && editor.zoomColumn = 40 && editor.markStep
            && editor.steps.Length = 2 && !editor.stepEnabled.Value && editor.clearTrackButton.Enabled,
            "recipe restores selection, disabled steps, and tracking")
        restored := editor.AdjustedImage(editor.Values())
        Check(restored.width = expected.width && restored.height = expected.height
            && CleanerEqual(restored.pixels, expected.pixels), "recipe round trip reproduces every adjusted pixel")
        RequireError(() => WefaxParseRecipe(image, StrReplace(text, '"row": 26', '"row": 11')), "unique and ascending")
        RequireError(() => WefaxParseRecipe(image, StrReplace(text, '"version": 1', '"version": "1"')), "version")
        RequireError(() => WefaxParseRecipe(image, StrReplace(text, '"bottom": 3', '"bottom": ' (image.height - 1))),
            "Crop must leave")
        RequireError(() => WefaxParseRecipe(image, text "null"), "Unexpected content")
        other := WefaxLoad(source)
        NumPut("UChar", 1 ^ NumGet(other.pixels, 0, "UChar"), other.pixels, 0)
        RequireError(() => WefaxParseRecipe(other, text), "different source image")
        Check(editor.RecipeText() == text, "rejected recipes leave the existing corrections intact")
        WefaxWriteNew(png, WefaxSavePng.Bind(restored))
        RequireError(() => WefaxWriteNew(png, WefaxSavePng.Bind(image)), "already exists")
        Check(CleanerEqual(WefaxLoad(png).pixels, expected.pixels)
            && CleanerEqual(CleanerRead(source), original) && CleanerEqual(CleanerRead(log), snapshot),
            "PNG-only export has no guides and never overwrites the original or edits the ADIF")
    } finally editor.Close()
}

TestWefaxDialogFolders(root, images) {
    prefs := root "\preferences.ini"
    Check(WefaxDialogStart(prefs, "json") = "" && WefaxDialogStart(prefs, "png", "chart_adjusted.png") = "chart_adjusted.png",
        "first use keeps the native folder default and suggested filename")
    WefaxRememberDialogFolder(prefs, "json", root "\recipe.json")
    WefaxRememberDialogFolder(prefs, "png", images "\chart_adjusted.png")
    Check(WefaxDialogStart(prefs, "json") = root "\" && WefaxDialogStart(prefs, "json", "recipe.json") = root "\recipe.json"
        && WefaxDialogStart(prefs, "png", "chart_adjusted.png") = images "\chart_adjusted.png",
        "JSON import/export share a folder read from disk; PNG remembers its own folder and keeps its filename")
    WefaxRememberDialogFolder(prefs, "json", root "\missing-folder\recipe.json")
    Check(WefaxDialogStart(prefs, "json") = "" && WefaxDialogStart(prefs, "png", "chart_adjusted.png") = images "\chart_adjusted.png",
        "an unavailable remembered folder falls back without changing the other dialog")
    FileAppend("PASS: persisted JSON/PNG dialog folders and unavailable-folder fallback.`n", "*")
}

TestWefaxTrack() {
    width := 160, height := 112
    image := {width: width, height: height, pixels: Buffer(width * height * 4, 255)}
    for row in [0, 1, 2, 3]
        Check(!WefaxTrackLine(image, row, 80).found, "blank anchors do not start a track")
    Loop 96 {
        row := A_Index - 1
        x := 80 + row // 10 + (row >= 48 ? 5 : 0)
        for offset in [-2, -1, 0, 1, 2]
            NumPut("UInt", 0xff222222, image.pixels, (row * width + x + offset) * 4)
    }
    track := WefaxTrackLine(image, 24, 82)
    Check(track.found && track.first = 0 && track.last >= 84 && track.last < 100
        && track.jumps >= 1 && track.offsets[height] = 0,
        "line tracker follows drift and a jump, then stops at the blank tail (rows "
        track.first " to " track.last ", jumps: " track.jumps ")")
    corrected := WefaxTransform(image, 0, 0, [], {top: 0, bottom: 0, left: 0, right: 0}, track.offsets)
    for row in [0, 24, 42, 60, 84]
        Check(WefaxLight(corrected, 82, row) < 70 && WefaxLight(corrected, 85, row) > 200,
            "known line is straightened at sampled rows")
}

TestWefaxSteps() {
    width := 240, height := 84, baseline := {width: width, height: height, pixels: Buffer(width * height * 4)}
    pattern := [], seed := 37
    Loop width {
        seed := Mod(seed * 16807, 2147483647)
        color := Mod(seed, 5) < 2 ? 24 : 232
        pattern.Push(0xff000000 | color * 0x10101)
    }
    Loop height {
        y := A_Index - 1
        Loop width
            NumPut("UInt", pattern[A_Index], baseline.pixels, 4 * (y * width + A_Index - 1))
    }
    Check(!WefaxRepairSteps(baseline, 0).Length, "continuous texture does not trigger a step repair")
    stepped := WefaxTransform(baseline, 0, 0, [{row: 30, shift: -5}, {row: 60, shift: 4}])
    repairs := WefaxRepairSteps(stepped, 0)
    Check(repairs.Length = 2 && repairs[1].shift = 5 && repairs[2].shift = -4
        && Abs(repairs[1].row - 30) <= 1 && Abs(repairs[2].row - 60) <= 1,
        "step detector finds both signed jumps near their row boundaries")
    restored := WefaxTransform(stepped, 0, 0, repairs)
    for row in [10, 40, 70] {
        offset := row * width * 4
        Check(DllCall("ntdll\RtlCompareMemory", "Ptr", baseline.pixels.Ptr + offset,
            "Ptr", restored.pixels.Ptr + offset, "UPtr", width * 4, "UPtr") = width * 4,
            "step repair reconnects the original rows without changing pixels")
    }
}

TestCopiedWefax(path) {
    processed := 0, suggested := 0
    pattern := DirExist(path) ? path "\*.png" : path
    Loop Files pattern, "F" {
        image := WefaxLoad(A_LoopFileFullPath)
        suggestion := WefaxAutoAlign(image, 0)
        if suggestion.found {
            adjusted := WefaxTransform(image, 0, suggestion.offset)
            Check(adjusted.width = image.width && adjusted.height = image.height, "copied image dimensions")
            suggested++
        }
        processed++
        if processed = 8
            break
    }
    Check(processed > 0, "no copied WEFAX PNGs found at: " path)
    FileAppend("PASS: opened " processed " copied WEFAX PNGs read-only; Auto Align suggested offsets for "
        suggested ". Visual accuracy is not asserted for unlabeled samples.`n", "*")
}

TestCleanup(operation, path) {
    try operation.Call(path)
    catch as problem {
        TestReport(problem, "cleanup: " path)
        return false
    }
    return true
}

TestReport(problem, context) {
    FileAppend("FAIL (" context "): " problem.Message "`n" problem.Extra "`n" problem.Stack "`n", "**")
}

TestAbort(problem, mode) {
    TestReport(problem, mode)
    ExitApp(1)
}

Record(mode, notes) {
    return "<MODE:" StrLen(mode) ">" mode "<QSO_DATE:8>20261119<TIME_ON:6>140000<NOTES:"
        . (StrPut(notes, "UTF-8") - 1) ">" notes "<EOR>`r`n"
}

WriteText(path, text) {
    stream := FileOpen(path, "w", "UTF-8-RAW")
    try stream.Write(text)
    finally stream.Close()
}

Check(condition, message) {
    if !condition
        throw Error(message)
}

RequireError(operation, expected) {
    try operation.Call()
    catch as problem {
        Check(InStr(problem.Message, expected), problem.Message)
        return
    }
    throw Error("Expected error: " expected)
}

ClosedBlocked() {
    throw Error("simulated FLdigi process")
}
