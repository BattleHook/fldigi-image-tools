#Requires AutoHotkey v2.0

CleanerReport(problem, context) {
    text := "[" A_NowUTC " UTC] " context ": " problem.Message "`n"
        . problem.Extra "`n" problem.Stack "`n"
    folder := A_ScriptDir "\Logs"
    try {
        DirCreate(folder)
        FileAppend(text, folder "\Cleaner-errors.log", "UTF-8-RAW")
    } catch as failure {
        OutputDebug(text "Could not write Logs\Cleaner-errors.log: " failure.Message)
        try FileAppend(text "Could not write Logs\Cleaner-errors.log: " failure.Message "`n", "**")
        return false
    }
    return true
}

CleanerConfig(path) {
    logPath := CleanerExpand(IniRead(path, "Logbook", "Path"))
    if !CleanerLocalPath(logPath) || !RegExMatch(logPath, "i)\.adi(f)?$")
        throw Error("Set Logbook/Path to a local ADIF file.")
    rules := []
    seen := Map()
    for section in StrSplit(IniRead(path), "`n", "`r") {
        if !RegExMatch(section, "i)^Rule\s+(.+)$", &name)
            continue
        enabled := IniRead(path, section, "Enabled")
        if enabled != "0" && enabled != "1"
            throw Error(section ": Enabled must be 0 or 1.")
        if enabled = "0"
            continue
        mode := StrUpper(Trim(IniRead(path, section, "Mode")))
        submode := StrUpper(Trim(IniRead(path, section, "Submode", "")))
        field := StrUpper(Trim(IniRead(path, section, "Field")))
        prefix := Trim(IniRead(path, section, "Prefix"))
        root := RTrim(CleanerExpand(IniRead(path, section, "Folder")), "\")
        extensions := Trim(IniRead(path, section, "Extensions"))
        key := mode "/" submode
        if !RegExMatch(mode, "^[A-Z0-9_]+$") || !RegExMatch(submode, "^[A-Z0-9_]*$")
            || !RegExMatch(field, "^[A-Z0-9_]+$") || !RegExMatch(prefix, "i)^[A-Z0-9_-]+:$")
            || !RegExMatch(extensions, "i)^[a-z0-9]+(?:\|[a-z0-9]+)*$")
            || !CleanerLocalPath(root) || seen.Has(key)
            throw Error(section ": invalid or duplicate rule. See README.md.")
        seen[key] := true
        rules.Push({name: name[1], mode: mode, submode: submode, field: field, prefix: prefix,
            root: root, extensions: extensions})
    }
    if !rules.Length
        throw Error("Enable at least one image rule in Cleaner.ini.")
    return {log: logPath, rules: rules}
}

CleanerExpand(value) => StrReplace(Trim(value), "{profile}", EnvGet("USERPROFILE"), false)

CleanerSafeRelative(value) {
    return value != "" && !RegExMatch(value, '[^\x20-\x7E]|[<>:"/|?*]')
        && !RegExMatch(value, "(^|\\)(?:\\|$)|[. ](?:\\|$)")
        && !RegExMatch(value, "i)(^|\\)(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:[.\\]|$)")
}

CleanerLocalPath(value) {
    return RegExMatch(value, "i)^[A-Z]:\\") && CleanerSafeRelative(SubStr(value, 4))
        && DllCall("GetDriveTypeW", "Str", SubStr(value, 1, 3), "UInt") = 3
}

CleanerRead(path, locked := false) {
    ; While applying, allow rename but deny other readers and writers until the swap completes.
    handle := DllCall("CreateFileW", "Str", path, "UInt", 0x80000000,
        "UInt", locked ? 4 : 7, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
    if handle = -1
        throw OSError(A_LastError, "CleanerRead", path)
    if locked
        return handle
    try return CleanerReadHandle(handle)
    finally DllCall("CloseHandle", "Ptr", handle)
}

CleanerReadHandle(handle) {
    size := 0
    if !DllCall("GetFileSizeEx", "Ptr", handle, "Int64*", &size)
        throw OSError()
    if size < 1 || size > 32 * 1024 * 1024
        throw Error("Expected a non-empty ADIF file of at most 32 MiB.")
    bytes := Buffer(size)
    count := 0
    if !DllCall("ReadFile", "Ptr", handle, "Ptr", bytes, "UInt", size, "UInt*", &count, "Ptr", 0)
        throw OSError()
    if count != size
        throw Error("The log changed while being read. Scan again.")
    return bytes
}

CleanerEqual(a, b) => a.Size = b.Size
    && DllCall("ntdll\RtlCompareMemory", "Ptr", a, "Ptr", b, "UPtr", a.Size, "UPtr") = a.Size

CleanerParse(bytes) {
    ; ISO-8859-1 is a one-byte view for FLdigi's field offsets, not an output encoding.
    text := StrGet(bytes, bytes.Size, "CP28591")
    if StrLen(text) != bytes.Size
        throw Error("Unsupported ADIF encoding or embedded NUL.")
    cursor := SubStr(text, 1, 3) = Chr(239) Chr(187) Chr(191) ? 4 : 1
    ; Advance past FLdigi's optional File: line without changing the source bytes.
    if RegExMatch(text, "i)\GFile:[^<>\r\n]+(?:\r\n|\n|\r)(?=[ \t\r\n]*<ADIF_VER:)", &preamble, cursor)
        cursor += preamble.Len
    records := [], fields := Map(), spans := Map(), header := false, start := 0
    while cursor <= StrLen(text) {
        if RegExMatch(text, "\G[ \t\r\n]+", &space, cursor)
            cursor += space.Len
        if cursor > StrLen(text)
            break
        if !RegExMatch(text, "i)\G<([a-z0-9_]+)(?::([0-9]{1,9})(?::[a-z])?)?>", &tag, cursor)
            throw Error("Unexpected ADIF data at byte " (cursor - 1) ". No changes were made.")
        if !start
            start := cursor - 1
        tagStart := cursor - 1
        cursor += tag.Len
        name := StrUpper(tag[1])
        if name = "EOH" || name = "EOR" {
            if tag[2] != "" || (name = "EOH" ? header || !fields.Count : !header || !fields.Count)
                throw Error("Unexpected ADIF marker: " name)
            if name = "EOR"
                records.Push({start: start, end: cursor - 1, fields: fields, spans: spans})
            else
                header := true
            fields := Map(), spans := Map(), start := 0
        } else {
            if tag[2] = "" || fields.Has(name)
                throw Error("Missing field length or duplicate ADIF field: " name)
            length := Integer(tag[2])
            if cursor + length - 1 > bytes.Size
                throw Error("Truncated ADIF field: " name)
            fields[name] := SubStr(text, cursor, length)
            spans[name] := {start: tagStart, data: cursor - 1, length: length,
                tag: tag[0], end: cursor + length - 1}
            cursor += length
        }
    }
    if !header || fields.Count
        throw Error("Missing ADIF header or incomplete final record.")
    return records
}

CleanerAttributes(path) {
    attr := DllCall("GetFileAttributesW", "Str", path, "UInt")
    return {attr: attr, error: attr = 0xFFFFFFFF ? A_LastError : 0}
}

CleanerFolder(path) {
    status := CleanerAttributes(path)
    return !status.error && (status.attr & 0x10) && !(status.attr & 0x1000)
}

CleanerScan(bytes, rules) {
    records := CleanerParse(bytes)
    candidates := [], images := [], missingFolders := Map(), skipped := 0
    for rule in rules
        if !CleanerFolder(rule.root)
            missingFolders[rule.name] := rule.root
    for index, record in records {
        fields := record.fields
        match := 0, matches := 0
        for rule in rules {
            if fields.Get("MODE", "") = rule.mode
                && (rule.submode = "" || fields.Get("SUBMODE", "") = rule.submode)
                match := rule, matches += 1
        }
        if !matches
            continue
        if matches > 1 || missingFolders.Has(match.name) {
            skipped++
            continue
        }
        note := fields.Get(match.field, "")
        if InStr(note, match.prefix) != 1 {
            skipped++
            continue
        }
        lines := StrSplit(StrReplace(note, "`r`n", "`n"), "`n")
        reference := Trim(SubStr(lines[1], StrLen(match.prefix) + 1))
        path := CleanerImagePath(reference, match)
        if !path {
            skipped++
            continue
        }
        enhanced := ""
        if lines.Length > 1 {
            if lines.Length != 2 || match.field != "NOTES" || InStr(lines[2], "ENH:", true) != 1
                || !(enhanced := CleanerImagePath(SubStr(lines[2], 5), match))
                || enhanced != CleanerEnhancedPath(path) {
                skipped++
                continue
            }
        }
        state := CleanerImageState(path)
        enhState := enhanced ? CleanerImageState(enhanced) : "missing"
        SplitPath(path, &filename)
        row := {id: index, record: record, mode: match.name, path: path, enhanced: enhanced,
            file: filename, date: fields.Get("QSO_DATE", ""), time: fields.Get("TIME_ON", "")}
        if state = "present" {
            if match.mode = "FAX" && match.field = "NOTES" && RegExMatch(path, "i)\.png$")
                images.Push(row)
            continue
        }
        if enhState = "present"
            continue
        if state != "missing" || enhState != "missing" {
            skipped++
            continue
        }
        candidates.Push(row)
    }
    return {candidates: candidates, images: images, total: records.Length, skipped: skipped, missingFolders: missingFolders}
}

CleanerImagePath(reference, rule) {
    if !RegExMatch(reference, "i)\.(" rule.extensions ")$")
        return ""
    if InStr(reference, "\") && InStr(reference, rule.root "\") != 1
        return ""
    path := InStr(reference, "\") ? reference : rule.root "\" reference
    return CleanerLocalPath(path) ? path : ""
}

CleanerImageState(path) {
    attributes := CleanerAttributes(path)
    if !attributes.error && !(attributes.attr & 0x10)
        return "present"
    SplitPath(path, , &parent)
    return attributes.error = 2 && CleanerFolder(parent) ? "missing" : "unknown"
}

CleanerEnhancedPath(path) {
    SplitPath(path, , &parent, &extension, &stem)
    return parent "\" stem "_enh." extension
}

CleanerRecycleOriginal(config, snapshot, selected, requireClosed, recycle) {
    requireClosed.Call()
    fresh := CleanerRead(config.log)
    if !CleanerEqual(fresh, snapshot)
        throw Error("The log changed since opening this list. Reopen WEFAX Images.")
    for row in CleanerScan(fresh, config.rules).images {
        if row.id != selected.id || row.path != selected.path
            continue
        attributes := CleanerAttributes(row.path)
        if attributes.error || (attributes.attr & 0x410)
            throw Error("The original is missing or is not a regular PNG file.")
        requireClosed.Call()
        recycle.Call(row.path)
        if CleanerImageState(row.path) != "missing"
            throw Error("Windows did not move the original to the Recycle Bin.")
        return
    }
    throw Error("The original is no longer linked or available. Reopen WEFAX Images.")
}

CleanerWindowsRecycle(path) {
    operation := ComObject("{3AD05575-8857-4850-9277-11B85BDB8E09}", "{947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8}")
    ; Require Recycle Bin semantics, with no Shell prompts or permanent-delete fallback.
    ComCall(5, operation, "UInt", 0x00080000 | 0x00100000 | 0x1000 | 0x0400 | 0x0040 | 0x0010 | 0x0004)
    iid := Buffer(16), item := 0
    DllCall("ole32\CLSIDFromString", "Str", "{43826D1E-E718-42EE-BC55-A1E261C37BFE}", "Ptr", iid, "HRESULT")
    DllCall("shell32\SHCreateItemFromParsingName", "Str", path, "Ptr", 0, "Ptr", iid, "Ptr*", &item, "HRESULT")
    try {
        ComCall(18, operation, "Ptr", item, "Ptr", 0)
        ComCall(21, operation)
        aborted := 0
        ComCall(22, operation, "Int*", &aborted)
        if aborted
            throw Error("Windows did not complete the Recycle Bin operation.")
    } finally ObjRelease(item)
}

CleanerTemp(parent) {
    name := Buffer(520, 0)
    if !DllCall("GetTempFileNameW", "Str", parent, "Str", "FLC", "UInt", 0, "Ptr", name, "UInt")
        throw OSError()
    return StrGet(name, "UTF-16")
}

CleanerWrite(path, bytes, drops := unset) {
    stream := FileOpen(path, "w", "CP0")
    try {
        cursor := 0
        if IsSet(drops)
            for record in drops {
                CleanerWriteRange(stream, bytes, cursor, record.start - cursor)
                cursor := record.end
            }
        CleanerWriteRange(stream, bytes, cursor, bytes.Size - cursor)
        if !DllCall("FlushFileBuffers", "Ptr", stream.Handle)
            throw OSError()
    } finally stream.Close()
}

CleanerWriteRange(stream, bytes, start, count) {
    if count && stream.RawWrite(bytes.Ptr + start, count) != count
        throw Error("Could not write the complete ADIF data.")
}

CleanerBackup(log, bytes, parent) {
    stage := CleanerTemp(parent)
    try {
        CleanerWrite(stage, bytes)
        backup := log "." FormatTime(A_Now, "yyyyMMdd-HHmmss") "." A_TickCount ".bak"
        if !DllCall("MoveFileExW", "Str", stage, "Str", backup, "UInt", 8)
            throw OSError(A_LastError, "CleanerBackup", "Could not save backup.")
        stage := ""
        return backup
    } finally CleanerDiscard(stage)
}

CleanerDiscard(path) {
    if path = ""
        return
    try FileDelete(path)
    catch as problem
        CleanerReport(problem, "Removing temporary file " path)
}

CleanerReplace(stage, destination) {
    ; POSIX rename replaces a name even while the old file is held open for verification.
    handle := DllCall("CreateFileW", "Str", stage, "UInt", 0x10000, "UInt", 7,
        "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
    if handle = -1
        throw OSError(A_LastError, , stage)
    try {
        offset := A_PtrSize = 8 ? 16 : 8
        size := (StrPut(destination, "UTF-16") - 1) * 2
        rename := Buffer(offset + 4 + size + 2, 0)
        NumPut("UInt", 3, rename, 0)
        NumPut("UInt", size, rename, offset)
        StrPut(destination, rename.Ptr + offset + 4, "UTF-16")
        if !DllCall("SetFileInformationByHandle", "Ptr", handle, "Int", 22,
            "Ptr", rename, "UInt", rename.Size)
            throw OSError(A_LastError, , destination)
    } finally DllCall("CloseHandle", "Ptr", handle)
}

CleanerApply(config, snapshot, selected, requireClosed) {
    if !selected.Count
        throw Error("Check at least one candidate first.")
    requireClosed.Call()
    source := CleanerRead(config.log, true)
    stage := ""
    try {
        fresh := CleanerReadHandle(source)
        if !CleanerEqual(fresh, snapshot)
            throw Error("The log changed since Scan. Scan again.")
        drops := []
        for row in CleanerScan(fresh, config.rules).candidates
            if selected.Has(row.id) && selected[row.id] == row.path
                drops.Push(row.record)
        if drops.Length != selected.Count
            throw Error("One or more selected image paths changed or cannot be verified. Scan again.")
        SplitPath(config.log, , &parent)
        stage := CleanerTemp(parent)
        CleanerWrite(stage, fresh, drops)
        CleanerParse(CleanerRead(stage))
        backup := CleanerBackup(config.log, fresh, parent)
        requireClosed.Call()
        try CleanerReplace(stage, config.log)
        catch as problem
            throw Error("Log replacement failed. Backup: " backup ". " problem.Message, -1, problem.Extra)
        stage := ""
        return backup
    } finally {
        DllCall("CloseHandle", "Ptr", source)
        CleanerDiscard(stage)
    }
}
