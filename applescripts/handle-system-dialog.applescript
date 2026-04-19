-- handle-system-dialog.applescript
-- Click a button on the frontmost system dialog or sheet.
--
-- Usage: osascript.sh run handle-system-dialog <button-label>
--   button-label: exact text of button to click (e.g. "OK", "Replace", "Allow", "Delete")
--
-- Returns: "clicked: <button>" on success
-- Errors:  execution error if dialog not found or button not present
--
-- Requires: Accessibility permission (System Settings → Privacy & Security → Accessibility)

on run argv
    if (count of argv) < 1 then
        error "Usage: handle-system-dialog <button-label>" number -1700
    end if

    set targetButton to item 1 of argv

    tell application "System Events"
        -- Find the frontmost process
        set frontProc to first process whose frontmost is true
        set procName to name of frontProc

        -- Try sheets first (document-modal), then windows with buttons
        set clickedSomething to false

        tell frontProc
            -- Check for sheets attached to windows
            repeat with w in windows
                if (count of sheets of w) > 0 then
                    tell sheet 1 of w
                        try
                            click button targetButton
                            set clickedSomething to true
                        end try
                    end tell
                end if
                if clickedSomething then exit repeat
            end repeat

            -- Check for dialogs / alert panels (no sheets found)
            if not clickedSomething then
                repeat with w in windows
                    try
                        click button targetButton of w
                        set clickedSomething to true
                        exit repeat
                    end try
                end repeat
            end if
        end tell

        if not clickedSomething then
            error "No dialog found with button '" & targetButton & "' in " & procName number -1728
        end if

        return "clicked: " & targetButton & " (in " & procName & ")"
    end tell
end run
