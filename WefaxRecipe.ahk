#Requires AutoHotkey v2.0

WefaxPixelHash(image) {
    if !image.HasOwnProp("pixelHash") {
        digest := Buffer(32), size := digest.Size
        if !DllCall("crypt32\CryptHashCertificate2", "WStr", "SHA256", "UInt", 0, "Ptr", 0,
            "Ptr", image.pixels, "UInt", image.pixels.Size, "Ptr", digest, "UInt*", &size)
            throw OSError()
        hash := ""
        Loop size
            hash .= Format("{:02x}", NumGet(digest, A_Index - 1, "UChar"))
        image.pixelHash := hash
    }
    return image.pixelHash
}

WefaxRecipeText(image, values, crop, steps, track, row, column, marked) {
    text := '{`n  "version": 1,`n  "source": {"width": ' image.width ', "height": ' image.height
        . ', "pixelSha256": "' WefaxPixelHash(image) '"},`n'
    text .= '  "tilt": ' values.tilt ',`n  "alignment": ' values.alignment ',`n'
    text .= '  "crop": {"top": ' crop.top ', "bottom": ' crop.bottom ', "left": ' crop.left
        . ', "right": ' crop.right '},`n  "steps": ['
    for step in steps {
        enabled := !step.HasOwnProp("enabled") || step.enabled
        ; Store the same one-based row and signed movement shown in the editor.
        text .= (A_Index > 1 ? "," : "") '`n    {"row": ' (step.row + 1) ', "shift": ' (-step.shift)
            . ', "enabled": ' enabled '}'
    }
    text .= (steps.Length ? "`n  " : "") '],`n  "trackOffsets": ['
    for offset in track
        text .= (A_Index > 1 ? ", " : "") offset
    return text '],`n  "selection": {"row": ' (row + 1) ', "column": ' (column + 1)
        . ', "marked": ' (!!marked) '}`n}`n'
}

; This private JSON reader accepts the v1 recipe's ASCII keys, hash, and integer-only data.
class WefaxRecipeReader {
    Token(&text, pattern) {
        if !RegExMatch(text, "\G[ `t`r`n]*(" pattern ")", &match, this.pos)
            throw ValueError("Invalid recipe JSON at position " this.pos ".")
        this.pos += match.Len
        return match[1]
    }

    Value(&text, depth := 0) {
        if depth > 4
            throw ValueError("Recipe JSON is nested too deeply.")
        token := this.Token(&text, '[{\[]|"[A-Za-z0-9]+"|-?(?:0|[1-9][0-9]{0,8})')
        switch token {
            case "{", "[":
                parsingObject := token = "{"
                result := parsingObject ? Map() : []
                closing := parsingObject ? "}" : "]"
                if RegExMatch(text, "\G[ `t`r`n]*\" closing, &end, this.pos) {
                    this.pos += end.Len
                    return result
                }
                loop {
                    if parsingObject {
                        key := Trim(this.Token(&text, '"[A-Za-z][A-Za-z0-9]*"'), '"')
                        if result.Has(key)
                            throw ValueError("Duplicate recipe field: " key ".")
                        this.Token(&text, ":")
                        result[key] := this.Value(&text, depth + 1)
                    } else
                        result.Push(this.Value(&text, depth + 1))
                    if this.Token(&text, ",|\" closing) = closing
                        return result
                }
            default:
                return SubStr(token, 1, 1) = '"' ? Trim(token, '"') : Integer(token)
        }
    }

    Parse(&text) {
        this.pos := 1
        value := this.Value(&text)
        if !RegExMatch(text, "\G[ `t`r`n]*\z", , this.pos)
            throw ValueError("Unexpected content after the recipe JSON.")
        return value
    }
}

WefaxRecipeObject(value, fields) {
    if !(value is Map) || value.Count != fields.Length
        throw ValueError("Recipe does not have the expected fields.")
    for field in fields
        if !value.Has(field)
            throw ValueError("Missing recipe field: " field ".")
    return value
}

WefaxRecipeInt(value, low, high, field) {
    if Type(value) != "Integer" || value < low || value > high
        throw ValueError("Invalid recipe value for " field ".")
    return value
}

WefaxParseRecipe(image, text) {
    data := WefaxRecipeObject(WefaxRecipeReader().Parse(&text),
        ["version", "source", "tilt", "alignment", "crop", "steps", "trackOffsets", "selection"])
    WefaxRecipeInt(data["version"], 1, 1, "version")
    width := image.width, height := image.height
    source := WefaxRecipeObject(data["source"], ["width", "height", "pixelSha256"])
    if Type(source["width"]) != "Integer" || source["width"] != width
        || Type(source["height"]) != "Integer" || source["height"] != height
        || Type(source["pixelSha256"]) != "String" || source["pixelSha256"] != WefaxPixelHash(image)
        throw ValueError("This recipe belongs to a different source image.")
    values := {tilt: WefaxRecipeInt(data["tilt"], -width, width, "tilt"),
        alignment: WefaxRecipeInt(data["alignment"], -width, width, "alignment")}
    sides := WefaxRecipeObject(data["crop"], ["top", "bottom", "left", "right"])
    crop := {}
    for side, amount in sides
        crop.%side% := WefaxRecipeInt(amount, 0, (side = "left" || side = "right" ? width : height) - 1, side)
    if crop.left + crop.right >= width || crop.top + crop.bottom >= height
        throw ValueError("Crop must leave at least one row and one column.")
    steps := [], last := 0
    if !(data["steps"] is Array) || data["steps"].Length > height
        throw ValueError("Invalid recipe steps.")
    for entry in data["steps"] {
        step := WefaxRecipeObject(entry, ["row", "shift", "enabled"])
        last := WefaxRecipeInt(step["row"], last + 1, height, "step row (must be unique and ascending)")
        shift := WefaxRecipeInt(step["shift"], -width, width, "step shift")
        if !shift
            throw ValueError("A recipe step must have a nonzero shift.")
        steps.Push({row: last - 1, shift: -shift, enabled: WefaxRecipeInt(step["enabled"], 0, 1, "step enabled")})
    }
    track := data["trackOffsets"]
    if !(track is Array) || (track.Length && track.Length != height)
        throw ValueError("Track Line offsets must be empty or contain one value per source row.")
    for offset in track
        WefaxRecipeInt(offset, -width, width, "Track Line offset")
    selection := WefaxRecipeObject(data["selection"], ["row", "column", "marked"])
    return {values: values, crop: crop, steps: steps, track: track,
        row: WefaxRecipeInt(selection["row"], 1, height, "selected row") - 1,
        column: WefaxRecipeInt(selection["column"], 1, width, "selected column") - 1,
        marked: WefaxRecipeInt(selection["marked"], 0, 1, "row marker")}
}

WefaxReadRecipe(path, image) {
    stream := FileOpen(path, "r", "UTF-8")
    try {
        if stream.Length > 1024 + image.height * 128
            throw ValueError("Recipe file is too large for this image.")
        return WefaxParseRecipe(image, stream.Read())
    } finally stream.Close()
}

WefaxWriteNew(destination, writer) {
    if FileExist(destination)
        throw ValueError("That filename already exists. Choose a new name.")
    SplitPath(destination, , &parent)
    stage := CleanerTemp(parent)
    try {
        writer.Call(stage)
        if !DllCall("MoveFileExW", "Str", stage, "Str", destination, "UInt", 8)
            throw OSError(A_LastError, , destination)
        stage := ""
    } finally CleanerDiscard(stage)
}

WefaxWriteRecipeText(text, path) {
    stream := FileOpen(path, "w", "UTF-8-RAW")
    try {
        if stream.Write(text) != StrLen(text) || !DllCall("FlushFileBuffers", "Ptr", stream.Handle)
            throw Error("Could not write the complete recipe.")
    } finally stream.Close()
}
