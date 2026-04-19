-- frontmost-info.applescript
-- Return info about the frontmost application as a JSON string.
--
-- Usage: osascript.sh run frontmost-info
--
-- Returns JSON:
--   {"app":"Safari","bundle_id":"com.apple.Safari","window_title":"Apple","windows":2,"pid":1234}
--
-- Requires: Accessibility permission for window title access.
-- Without accessibility, window_title will be "PERMISSION_DENIED".

on run argv
    tell application "System Events"
        -- application process (subclass of process) exposes bundle identifier
        set frontProc to first application process whose frontmost is true
        set procName to name of frontProc
        set bundleId to bundle identifier of frontProc
        if bundleId is missing value then set bundleId to ""
        set procPid to unix id of frontProc
        set winCount to count of windows of frontProc

        -- Try to get window title (needs accessibility)
        set winTitle to ""
        try
            if winCount > 0 then
                set winTitle to name of window 1 of frontProc
                if winTitle is missing value then set winTitle to ""
            end if
        on error
            set winTitle to "PERMISSION_DENIED"
        end try

        set procName to my jsonEscape(procName)
        set bundleId to my jsonEscape(bundleId)
        set winTitle to my jsonEscape(winTitle)

        return "{\"app\":\"" & procName & "\",\"bundle_id\":\"" & bundleId & "\",\"window_title\":\"" & winTitle & "\",\"windows\":" & winCount & ",\"pid\":" & procPid & "}"
    end tell
end run

on jsonEscape(str)
    set str to my replaceText(str, "\\", "\\\\")
    set str to my replaceText(str, "\"", "\\\"")
    return str
end jsonEscape

on replaceText(theText, oldStr, newStr)
    set AppleScript's text item delimiters to oldStr
    set textParts to text items of theText
    set AppleScript's text item delimiters to newStr
    set theResult to textParts as text
    set AppleScript's text item delimiters to ""
    return theResult
end replaceText
