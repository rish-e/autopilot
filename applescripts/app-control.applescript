-- app-control.applescript
-- Open, focus, quit, or check status of a macOS application.
--
-- Usage: osascript.sh run app-control <verb> <app-name-or-bundle-id>
--   verb: open | focus | quit | status | relaunch
--   app: application name (e.g. "Figma") or bundle ID (e.g. "com.figma.Desktop")
--
-- Returns: JSON-like status string, e.g. {"status":"running","app":"Figma","frontmost":false}

on run argv
    if (count of argv) < 2 then
        error "Usage: app-control <open|focus|quit|status|relaunch> <app-name-or-bundle-id>" number -1700
    end if

    set verb to item 1 of argv
    set appRef to item 2 of argv

    -- Detect whether appRef looks like a bundle ID (contains dots, no spaces)
    set isBundleId to false
    if appRef contains "." and appRef does not contain " " then
        set isBundleId to true
    end if

    if verb is "status" then
        return getStatus(appRef, isBundleId)

    else if verb is "open" then
        if isBundleId then
            tell application id appRef to activate
        else
            tell application appRef to activate
        end if
        delay 1
        return getStatus(appRef, isBundleId)

    else if verb is "focus" then
        tell application "System Events"
            set proc to missing value
            if isBundleId then
                try
                    set proc to first process whose bundle identifier is appRef
                end try
            else
                try
                    set proc to first process whose name is appRef
                end try
            end if
            if proc is missing value then
                error "App not running: " & appRef number -609
            end if
            set frontmost of proc to true
        end tell
        return getStatus(appRef, isBundleId)

    else if verb is "quit" then
        if isBundleId then
            tell application id appRef to quit
        else
            tell application appRef to quit
        end if
        delay 1
        return getStatus(appRef, isBundleId)

    else if verb is "relaunch" then
        -- Quit if running, then open
        try
            if isBundleId then
                tell application id appRef to quit
            else
                tell application appRef to quit
            end if
            delay 2
        end try
        if isBundleId then
            tell application id appRef to activate
        else
            tell application appRef to activate
        end if
        delay 1
        return getStatus(appRef, isBundleId)

    else
        error "Unknown verb: " & verb & ". Use open|focus|quit|status|relaunch." number -1700
    end if
end run

on getStatus(appRef, isBundleId)
    tell application "System Events"
        set proc to missing value
        if isBundleId then
            try
                set proc to first process whose bundle identifier is appRef
            end try
        else
            try
                set proc to first process whose name is appRef
            end try
        end if

        if proc is missing value then
            return "{\"status\":\"not_running\",\"app\":\"" & appRef & "\",\"frontmost\":false}"
        end if

        set procName to name of proc
        set isFront to frontmost of proc
        set frontStr to "false"
        if isFront then set frontStr to "true"

        return "{\"status\":\"running\",\"app\":\"" & procName & "\",\"frontmost\":" & frontStr & "}"
    end tell
end getStatus
