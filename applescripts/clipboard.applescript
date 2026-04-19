-- clipboard.applescript
-- Read or write the macOS clipboard (pasteboard).
--
-- Usage:
--   osascript.sh run clipboard get              # Print clipboard contents to stdout
--   osascript.sh run clipboard set <value>      # Set clipboard to value
--   osascript.sh run clipboard clear            # Clear clipboard
--
-- Returns:
--   get: clipboard text content (or "EMPTY" if clipboard has no text)
--   set: "ok"
--   clear: "ok"
--
-- Note: Only handles text content. Binary/image clipboard data returns "BINARY_CONTENT".

on run argv
    if (count of argv) < 1 then
        error "Usage: clipboard <get|set|clear> [value]" number -1700
    end if

    set verb to item 1 of argv

    if verb is "get" then
        try
            set clipText to the clipboard as text
            if clipText is "" then
                return "EMPTY"
            end if
            return clipText
        on error errMsg number errNum
            if errNum is -1700 then
                return "BINARY_CONTENT"
            end if
            error errMsg number errNum
        end try

    else if verb is "set" then
        if (count of argv) < 2 then
            error "clipboard set requires a value argument" number -1700
        end if
        set clipValue to item 2 of argv
        -- If more args, join them with spaces (handles shell word-splitting)
        if (count of argv) > 2 then
            set clipValue to ""
            repeat with i from 2 to count of argv
                if i > 2 then set clipValue to clipValue & " "
                set clipValue to clipValue & item i of argv
            end repeat
        end if
        set the clipboard to clipValue
        return "ok"

    else if verb is "clear" then
        set the clipboard to ""
        return "ok"

    else
        error "Unknown verb: " & verb & ". Use get|set|clear." number -1700
    end if
end run
