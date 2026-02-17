package.path = '/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;' .. package.path

local file = require 'fibers.io.file'
local fibers = require 'fibers'

---@alias ATCommand string
---@alias SerialPortPath string
---@alias ATResponseLine string

local function trim(input)
    -- Pattern matches non-printable characters and spaces at the start and end of the string
    -- %c matches control characters, %s matches all whitespace characters
    -- %z matches the character with representation 0x00 (NUL byte)
    return (input:gsub("^[%c%s%z]+", ""):gsub("[%c%s%z]+$", ""))
end

---@class AT
local at = {}

---Send an AT command to a serial port and collect response lines until OK/ERROR.
---
---Notes:
--- - Returns a list of non-empty response lines.
--- - On success, error is nil.
--- - On error, error may be a generic string ('error', 'unknown error') or a
---   numeric string parsed from +CME/+CMS.
---@param port SerialPortPath
---@param command ATCommand
---@return ATResponseLine[]? lines
---@return string error
function at.send(port, command)
    local st, _, err, result = fibers.run_scope(function()
        local reader, err = file.open(port, "r")
        if not reader then return "error opening AT read port: " .. err, nil end

        local writer = assert(file.open(port, "w"))
        if not writer then return "error opening AT write port: " .. err, nil end

        -- file write
        writer:write_chars(command .. '\r')

        writer:close()

        local res = {}

        while true do
            local line = reader:read_line()

            if not line then return 'unknown error', nil end

            line = trim(line)

            -- check for non-descriptive success/fail
            if line:find("^OK$") then
                reader:close()
                return res, nil
            elseif line:find("^ERROR$") then
                reader:close()
                return res, 'error'
            else
                -- check for descriptive fail
                local error_code
                error_code = line:match("^%+CME ERROR: (%d+)$")
                if error_code then
                    reader:close()
                    return error_code, res
                end
                error_code = line:match("^%+CMS ERROR: (%d+)$")
                if error_code then
                    reader:close()
                    return error_code, res
                end
            end

            if #line > 0 then table.insert(res, line) end
        end
    end)

    if st == 'ok' then
        return result, ""
    else
        return nil, err or "AT command failed"
    end
end

return at
