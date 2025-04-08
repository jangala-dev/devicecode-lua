package.path = '/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;' .. package.path

local file = require 'fibers.stream.file'
local op = require 'fibers.op'

local function trim(input)
    -- Pattern matches non-printable characters and spaces at the start and end of the string
    -- %c matches control characters, %s matches all whitespace characters
    -- %z matches the character with representation 0x00 (NUL byte)
    return (input:gsub("^[%c%s%z]+", ""):gsub("[%c%s%z]+$", ""))
end

local function send_with_context(ctx, port, command)
    local reader, err = file.open(port, "r")
    if not reader then return nil, "error opening AT read port: "..err end

    local writer = assert(file.open(port, "w"))
    if not writer then return nil, "error opening AT write port: "..err end

    -- file write
    op.choice(
        writer:write_chars_op(command..'\r'),
        ctx:done_op()
    ):perform()

    writer:close()

    if ctx:err() then reader:close() return nil, ctx:err() end

    local res = {}

    while true do
        local line = op.choice(
            reader:read_line_op(),
            ctx:done_op()
        ):perform()

        if ctx:err() then reader:close() return nil, ctx:err() end
        if not line then reader:close() return nil, 'unknown error' end

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
                return res, error_code
            end
            error_code = line:match("^%+CMS ERROR: (%d+)$")
            if error_code then
                reader:close()
                return res, error_code
            end
        end

        if #line > 0 then table.insert(res, line) end
    end
end

return {
    send_with_context = send_with_context
}