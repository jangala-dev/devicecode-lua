package.path = '/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;' .. package.path

local file  = require 'fibers.io.file'
local scope = require 'fibers.scope'

---@alias ATCommand string
---@alias SerialPortPath string
---@alias ATResponseLine string

---@class ATTerminalPattern
---@field pattern string  Lua pattern matched against trimmed lines
---@field is_error boolean  When true the matched line is returned as an error string

---@class ATSendOpts
---@field terminal_patterns ATTerminalPattern[]?

-- Usage example:
--
--   local op     = require 'fibers.op'
--   local sleep  = require 'fibers.sleep'
--   local fibers = require 'fibers'
--
--   while true do
--       local src, lines, err = fibers.perform(op.named_choice({
--           response = at.send_op(port, "AT+QGMR"),
--           timeout  = sleep.sleep_op(5),
--       }))
--       if src == "response" then
--           -- lines: ATResponseLine[]?, err: string?
--           break
--       end
--       -- timeout arm: loop retries with a fresh op; port re-opened cleanly
--   end

local function trim(input)
    -- Pattern matches non-printable characters and spaces at the start and end of the string
    -- %c matches control characters, %s matches all whitespace characters
    -- %z matches the character with representation 0x00 (NUL byte)
    return (input:gsub("^[%c%s%z]+", ""):gsub("[%c%s%z]+$", ""))
end

---@class AT
local at = {}

---Return an Op that sends an AT command and collects response lines until a
---terminal line is hit.
---
---The Op yields `(lines, err)`:
--- - On success: `lines` is a list of non-empty response lines, `err` is nil.
--- - On AT error: `lines` is the accumulated lines so far, `err` is a string
---   (`'error'`, `'unknown error'`, or a numeric code string from +CME/+CMS).
--- - On cancellation (e.g. the op loses a race against a timeout): `lines` is
---   nil, `err` is `'cancelled'`. The port is closed as part of losing the race.
---
---`opts.terminal_patterns` is an optional list of additional terminal patterns.
---Each entry is `{ pattern = string, is_error = bool }`. When a trimmed line
---matches, that line is appended to `lines` and the op completes. If `is_error`
---is true, the matched line is also returned as `err`.
---
---@param port SerialPortPath
---@param command ATCommand
---@param opts ATSendOpts?
---@return Op  -- yields (ATResponseLine[]?, string?)
function at.send_op(port, command, opts)
    local terminal_patterns = (opts and opts.terminal_patterns) or {}

    return scope.run_op(function(s)
        local reader, rd_err = file.open(port, "r")
        if not reader then
            return nil, "error opening AT read port: " .. rd_err
        end

        -- Centralised cleanup: reader is closed however this scope exits
        -- (success, AT error, unhandled error, or cancelled by losing a race).
        s:finally(function() reader:close() end)

        local writer, wr_err = file.open(port, "w")
        if not writer then
            return nil, "error opening AT write port: " .. wr_err
        end

        writer:write(command .. '\r')
        writer:close()

        local res = {}
        while true do
            local line, read_err = s:perform(reader:read_line_op())

            if not line then
                return nil, read_err or "unknown error"
            end

            line = trim(line)

            -- Built-in terminals
            if line:find("^OK$") then
                return res, nil
            elseif line:find("^ERROR$") then
                return res, "error"
            else
                local error_code = line:match("^%+CME ERROR: (%d+)$")
                                or line:match("^%+CMS ERROR: (%d+)$")
                if error_code then
                    return res, error_code
                end
            end

            -- User-supplied terminal patterns
            for _, tp in ipairs(terminal_patterns) do
                if line:find(tp.pattern) then
                    table.insert(res, line)
                    return res, tp.is_error and line or nil
                end
            end

            if #line > 0 then table.insert(res, line) end
        end
    end):wrap(function(st, _report, a, b)
        if st == 'ok' then return a, b end
        if st == 'cancelled' then return nil, 'cancelled' end
        -- 'failed': a is the primary error string
        return nil, a or "AT command failed"
    end)
end

return at
