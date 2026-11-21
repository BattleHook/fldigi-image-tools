#Requires AutoHotkey v2.0

WefaxGdi() {
    static token := 0, module := 0
    if token
        return
    if !module {
        module := DllCall("LoadLibraryW", "Str", A_WinDir "\System32\gdiplus.dll", "Ptr")
        if !module
            throw OSError()
    }
    input := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, input)
    WefaxCheck(DllCall("gdiplus\GdiplusStartup", "UPtr*", &token, "Ptr", input, "Ptr", 0), "starting GDI+")
    OnExit((*) => WefaxGdiShutdown(token))
}

WefaxGdiShutdown(token) {
    DllCall("gdiplus\GdiplusShutdown", "UPtr", token)
    return 0
}

WefaxCheck(code, action) {
    if code
        throw Error("Image error while " action " (GDI+ status " code ").")
}

WefaxLoad(path) {
    WefaxGdi()
    bitmap := 0
    WefaxCheck(DllCall("gdiplus\GdipCreateBitmapFromFile", "Str", path, "Ptr*", &bitmap), "opening PNG")
    try {
        width := 0, height := 0
        WefaxCheck(DllCall("gdiplus\GdipGetImageWidth", "Ptr", bitmap, "UInt*", &width), "reading width")
        WefaxCheck(DllCall("gdiplus\GdipGetImageHeight", "Ptr", bitmap, "UInt*", &height), "reading height")
        if !width || !height || width * height > 16000000
            throw Error("Image exceeds the 16 megapixel editing limit.")
        pixels := Buffer(width * height * 4)
        rect := Buffer(16, 0), data := Buffer(16 + 2 * A_PtrSize, 0)
        NumPut("Int", width, "Int", height, rect, 8)
        WefaxCheck(DllCall("gdiplus\GdipBitmapLockBits", "Ptr", bitmap, "Ptr", rect, "UInt", 1,
            "Int", 0x26200A, "Ptr", data), "reading pixels")
        try {
            stride := NumGet(data, 8, "Int"), scan := NumGet(data, 16, "Ptr")
            Loop height
                WefaxCopy(pixels.Ptr + (A_Index - 1) * width * 4, scan + (A_Index - 1) * stride, width * 4)
        } finally DllCall("gdiplus\GdipBitmapUnlockBits", "Ptr", bitmap, "Ptr", data)
        return {width: width, height: height, pixels: pixels}
    } finally DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap)
}

WefaxCopy(dest, source, count) {
    if count
        DllCall("ntdll\RtlMoveMemory", "Ptr", dest, "Ptr", source, "UPtr", count)
}

WefaxWrap(value, width) => Mod(Mod(value, width) + width, width)
WefaxTiltShift(y, height, tilt) => Round(tilt * y / Max(1, height - 1))

WefaxTransform(image, tilt, alignment, steps := [], crop := {top: 0, bottom: 0, left: 0, right: 0}, track := []) {
    width := image.width, height := image.height
    for amount in [crop.top, crop.bottom, crop.left, crop.right]
        if !IsInteger(amount) || amount < 0
            throw ValueError("Crop values must be nonnegative whole pixels.")
    keepRows := height - crop.top - crop.bottom
    keepCols := width - crop.left - crop.right
    if keepRows < 1 || keepCols < 1
        throw ValueError("Crop must leave at least one row and one column.")
    result := Buffer(keepCols * keepRows * 4)
    next := 1, correction := 0
    Loop keepRows {
        y := crop.top + A_Index - 1
        while next <= steps.Length && steps[next].row <= y {
            correction += steps[next].shift
            next++
        }
        shift := WefaxWrap(WefaxTiltShift(y, height, tilt) + correction - alignment + crop.left
            + (track.Length ? track[y + 1] : 0), width)
        src := image.pixels.Ptr + 4 * y * width, dst := result.Ptr + 4 * (A_Index - 1) * keepCols
        first := Min(keepCols, width - shift)
        WefaxCopy(dst, src + shift * 4, first * 4)
        WefaxCopy(dst + first * 4, src, (keepCols - first) * 4)
    }
    return {width: keepCols, height: keepRows, pixels: result}
}

WefaxTrackLine(image, row, column) {
    offsets := []
    Loop image.height
        offsets.Push(0)
    if row < 0 || row >= image.height || column < 10 || column >= image.width - 10
        return {found: false}
    template := WefaxTrackBand(image, row, column)
    if template.span < 45
        return {found: false}
    first := row, last := row, jumps := 0, changed := false
    for direction in [-1, 1] {
        previous := row, drift := 0
        while previous != (direction < 0 ? 0 : image.height - 1) {
            next := Max(0, Min(image.height - 1, previous + direction * 6))
            scores := [], best := 256, shift := drift
            Loop 17 {
                candidate := drift + A_Index - 9
                x := column + candidate
                if x < 10 || x >= image.width - 10 || Abs(candidate) > 160
                    continue
                band := WefaxTrackBand(image, next, x)
                if band.span < 45
                    continue
                cost := WefaxTrackCost(template, band)
                scores.Push({shift: candidate, cost: cost})
                if cost < best
                    best := cost, shift := candidate
            }
            if best > 27
                break
            rival := 256
            for match in scores
                if Abs(match.shift - shift) > 1
                    rival := Min(rival, match.cost)
            if rival - best < 4
                break
            distance := Abs(next - previous)
            jump := Abs(shift - drift) >= 3
            ; Locate an abrupt transition using the first intervening row that matches the new position better.
            boundary := distance
            if jump {
                Loop distance {
                    y := previous + direction * A_Index
                    oldCost := WefaxTrackCost(template, WefaxTrackBand(image, y, column + drift, 0))
                    newCost := WefaxTrackCost(template, WefaxTrackBand(image, y, column + shift, 0))
                    if newCost + 5 < oldCost {
                        boundary := A_Index
                        break
                    }
                }
                jumps++
            }
            Loop distance {
                value := jump ? (A_Index < boundary ? drift : shift)
                    : Round(drift + (shift - drift) * A_Index / distance)
                offsets[previous + direction * A_Index + 1] := value
                changed := changed || value != 0
            }
            previous := next, drift := shift
        }
        if direction < 0
            first := previous
        else
            last := previous
    }
    return {found: changed && last - first >= 12, offsets: offsets, first: first, last: last, jumps: jumps}
}

WefaxTrackBand(image, row, column, radius := 1) {
    values := [], low := 255, high := 0
    Loop 21 {
        x := column + A_Index - 11
        value := WefaxLight(image, x, row)
        if radius && row > 0 && row < image.height - 1 {
            above := WefaxLight(image, x, row - 1), below := WefaxLight(image, x, row + 1)
            value := Max(Min(above, below), Min(Max(above, below), value))
        }
        values.Push(value)
        low := Min(low, value), high := Max(high, value)
    }
    return {values: values, span: high - low}
}

WefaxTrackCost(template, band) {
    difference := 0
    for index, value in template.values
        difference += Abs(value - band.values[index])
    return difference / template.values.Length
}

WefaxLight(image, x, y) {
    pixel := NumGet(image.pixels, 4 * (y * image.width + x), "UInt")
    alpha := pixel >> 24
    gray := ((pixel & 255) * 29 + ((pixel >> 8) & 255) * 150 + ((pixel >> 16) & 255) * 77) >> 8
    return 255 - ((255 - gray) * alpha // 255)
}

WefaxAutoTilt(image, current) {
    width := image.width, height := image.height
    if width < 64 || height < 48
        return {found: false}
    rows := []
    Loop 24 {
        y := Round((height - 1) * (0.08 + (A_Index - 1) * 0.78 / 23))
        ink := Buffer(width)
        Loop width
            NumPut("UChar", 255 - WefaxLight(image, A_Index - 1, y), ink, A_Index - 1)
        rows.Push({y: y, ink: ink})
    }
    limit := Min(width // 5, 360), coarse := Max(2, Ceil(limit / 60))
    baseline := WefaxTiltScore(rows, width, height, current, 2)
    best := baseline, tilt := current, scores := Map()
    Loop 2 * (limit // coarse) + 1 {
        candidate := (A_Index - 1 - limit // coarse) * coarse
        score := WefaxTiltScore(rows, width, height, candidate, 2)
        scores[candidate] := score
        if score > best
            best := score, tilt := candidate
    }
    coarseTilt := tilt
    Loop 2 * coarse + 1 {
        candidate := coarseTilt + A_Index - 1 - coarse
        if Abs(candidate) > limit
            continue
        score := WefaxTiltScore(rows, width, height, candidate, 2)
        if score > best
            best := score, tilt := candidate
    }
    if tilt = current || best < baseline * 1.12 + 1
        return {found: false}
    for candidate, score in scores {
        if Abs(candidate - tilt) > 2 * coarse && score >= best * 0.96
            return {found: false}
    }
    return {found: true, tilt: tilt}
}

WefaxTiltScore(rows, width, height, tilt, stride) {
    shifts := []
    for row in rows
        shifts.Push(WefaxWrap(WefaxTiltShift(row.y, height, tilt), width))
    score := 0
    Loop width // stride {
        x := (A_Index - 1) * stride, dark := 0
        for index, row in rows {
            at := x + shifts[index]
            dark += NumGet(row.ink, at >= width ? at - width : at, "UChar")
        }
        ; Reward concentrated darkness that persists across sampled rows.
        score += Max(0, dark / rows.Length - 32) ** 2
    }
    return score / (width // stride)
}

WefaxRepairSteps(image, tilt) {
    width := image.width, height := image.height
    if width < 120 || height < 24
        return []
    ; Compare close rows across five independent chart regions, excluding the outside margins.
    regions := 5, samples := 24, radius := 12, offsets := []
    Loop regions * samples
        offsets.Push(Round(width * (0.10 + 0.80 * (A_Index - 0.5) / (regions * samples))))
    ink := Buffer(width * height)
    Loop height {
        y := A_Index - 1
        Loop width
            NumPut("UChar", 255 - WefaxLight(image, A_Index - 1, y), ink, y * width + A_Index - 1)
    }
    matches := [], peak := 0
    Loop height - 8 {
        row := A_Index + 3, top := row - 2, bottom := row + 1
        drift := WefaxTiltShift(bottom, height, tilt) - WefaxTiltShift(top, height, tilt)
        if Abs(drift) > 8
            continue
        votes := Map(), strengths := Map()
        Loop regions {
            region := A_Index, zero := 0, best := -samples * 256, runnerUp := best, winner := 0
            Loop 2 * radius + 1 {
                delta := A_Index - radius - 1, score := 0
                Loop samples {
                    x := offsets[(region - 1) * samples + A_Index]
                    a := NumGet(ink, top * width + x, "UChar")
                    b := NumGet(ink, bottom * width + WefaxWrap(x + drift + delta, width), "UChar")
                    score += 2 * Min(a, b) - Abs(a - b)
                }
                if delta = 0
                    zero := score
                if score > best {
                    runnerUp := best, best := score, winner := delta
                } else if score > runnerUp
                    runnerUp := score
            }
            if Abs(winner) >= 2 && best >= samples * 10
                && best - zero >= samples * 8 && best - runnerUp >= samples * 2 {
                votes[winner] := votes.Get(winner, 0) + 1
                strengths[winner] := strengths.Get(winner, 0) + best - zero
            }
        }
        for shift, count in votes {
            if count >= 3 && (!peak || strengths[shift] > peak.score)
                peak := {row: row, shift: shift, score: strengths[shift]}
        }
        if peak && row - peak.row >= 4
            matches.Push(peak), peak := 0
    }
    if peak
        matches.Push(peak)
    return matches
}

WefaxAutoAlign(image, tilt, alignment := 0) {
    ; A stripe can be a map feature. Reject darker margins, and require strong contrast on a tie.
    width := image.width, height := image.height
    if width < 32 || height < 16
        return {found: false}
    step := Max(3, Round(width / 80)), profile := []
    Loop width {
        x := A_Index - 1, sum := 0
        Loop 32 {
            y := Round((height - 1) * (0.1 + (A_Index - 1) * 0.8 / 31))
            sum += WefaxLight(image, WefaxWrap(x + WefaxTiltShift(y, height, tilt), width), y)
        }
        profile.Push(sum / 32)
    }
    best := 0, origin := 0
    Loop width {
        x := A_Index - 1
        middle := profile[x + 1]
        left := profile[WefaxWrap(x - step, width) + 1], right := profile[WefaxWrap(x + step, width) + 1]
        score := Max(Min(left, right) - middle, middle - Max(left, right))
        if score > best
            best := score, origin := x
    }
    current := WefaxWrap(-alignment, width)
    gain := WefaxMarginLight(profile, origin, step) - WefaxMarginLight(profile, current, step)
    if best < 26 || origin = current || (gain < 8 && (best < 80 || gain < -4))
        return {found: false}
    return {found: true, offset: origin > width / 2 ? width - origin : -origin}
}

WefaxMarginLight(profile, x, step) {
    sum := 0
    for distance in [-3, -2, 2, 3]
        sum += profile[WefaxWrap(x + distance * step, profile.Length) + 1]
    return sum / 4
}

WefaxDemo() {
    width := 360, height := 260, pixels := Buffer(width * height * 4)
    Loop height {
        y := A_Index - 1, drift := 117 + WefaxTiltShift(y, height, 25)
        Loop width {
            x := WefaxWrap(A_Index - 1 - drift, width)
            swirl := 31 * Sin(x / 33 + y / 99) + 20 * Cos(x / 58 - y / 18)
            line := Mod(Round(y + swirl + 100), 37) < 2
            grid := Mod(x, 45) = 0 || Mod(y, 38) = 0
            color := x < 3 || x >= width - 3 ? 15 : line ? 61 : grid ? 160 : 238
            NumPut("UInt", 0xff000000 | color * 0x10101, pixels, 4 * (y * width + A_Index - 1))
        }
    }
    return {width: width, height: height, pixels: pixels}
}

WefaxBitmap(image) {
    WefaxGdi()
    bitmap := 0
    WefaxCheck(DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", image.width, "Int", image.height,
        "Int", image.width * 4, "Int", 0x26200A, "Ptr", image.pixels, "Ptr*", &bitmap), "creating bitmap")
    return bitmap
}

WefaxZoomRegion(image, row, column, level := 0) {
    if level = 4
        return {image: image, left: 0, top: 0,
            row: row >= 0 && row < image.height ? row : -1,
            column: column >= 0 && column < image.width ? column : -1}
    factor := 2 ** level
    width := Min(120 * factor, image.width), height := Min(64 * factor, image.height)
    left := Max(0, Min(image.width - width, column - width // 2))
    top := Max(0, Min(image.height - height, row - height // 2))
    pixels := Buffer(width * height * 4)
    Loop height {
        y := A_Index - 1
        WefaxCopy(pixels.Ptr + y * width * 4,
            image.pixels.Ptr + ((top + y) * image.width + left) * 4, width * 4)
    }
    return {image: {width: width, height: height, pixels: pixels}, left: left, top: top,
        row: row >= 0 && row < image.height ? row - top : -1,
        column: column >= 0 && column < image.width ? column - left : -1}
}

WefaxPreviewBitmap(image, maxWidth, maxHeight, markerRow := -1, markerColumn := -1, pixelZoom := false) {
    scale := Min(maxWidth / image.width, maxHeight / image.height)
    width := Max(1, Floor(image.width * scale)), height := Max(1, Floor(image.height * scale))
    source := WefaxBitmap(image), target := 0, graphics := 0, handle := 0, pen := 0
    try {
        WefaxCheck(DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", width, "Int", height,
            "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &target), "sizing preview")
        WefaxCheck(DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", target, "Ptr*", &graphics), "creating preview")
        WefaxCheck(DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", graphics, "Int", pixelZoom ? 5 : 7), "setting preview quality")
        WefaxCheck(DllCall("gdiplus\GdipDrawImageRectI", "Ptr", graphics, "Ptr", source,
            "Int", 0, "Int", 0, "Int", width, "Int", height), "drawing preview")
        if (markerRow >= 0 && markerRow < image.height) || (markerColumn >= 0 && markerColumn < image.width) {
            WefaxCheck(DllCall("gdiplus\GdipCreatePen1", "UInt", 0xffe66b00,
                "Float", 2, "Int", 2, "Ptr*", &pen), "creating step marker")
            WefaxCheck(DllCall("gdiplus\GdipSetPenDashStyle", "Ptr", pen, "Int", 1), "styling step marker")
            if markerRow >= 0 && markerRow < image.height {
                y := Floor(markerRow * height / image.height)
                WefaxCheck(DllCall("gdiplus\GdipDrawLineI", "Ptr", graphics, "Ptr", pen, "Int", 0,
                    "Int", y, "Int", width - 1, "Int", y), "drawing row guide")
            }
            if markerColumn >= 0 && markerColumn < image.width {
                x := Floor(markerColumn * width / image.width)
                WefaxCheck(DllCall("gdiplus\GdipDrawLineI", "Ptr", graphics, "Ptr", pen, "Int", x,
                    "Int", 0, "Int", x, "Int", height - 1), "drawing column guide")
            }
        }
        WefaxCheck(DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", target, "Ptr*", &handle,
            "UInt", 0xff272727), "showing preview")
        return {handle: handle, width: width, height: height}
    } finally {
        if pen
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        if graphics
            DllCall("gdiplus\GdipDeleteGraphics", "Ptr", graphics)
        if target
            DllCall("gdiplus\GdipDisposeImage", "Ptr", target)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", source)
    }
}

WefaxSavePng(image, path) {
    bitmap := WefaxBitmap(image), encoder := Buffer(16)
    try {
        if DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", encoder)
            throw Error("Could not identify the Windows PNG encoder.")
        WefaxCheck(DllCall("gdiplus\GdipSaveImageToFile", "Ptr", bitmap, "Str", path, "Ptr", encoder,
            "Ptr", 0), "saving PNG")
    } finally DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap)
}
