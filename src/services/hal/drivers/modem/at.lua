package.path = '/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;' .. package.path

local file = require 'fibers.stream.file'
local op = require 'fibers.op'

local TERMINATOR_DEFAULTS = {
    "^OK$",
    "^ERROR$",
}

local function trim(input)
    -- Pattern matches non-printable characters and spaces at the start and end of the string
    -- %c matches control characters, %s matches all whitespace characters
    -- %z matches the character with representation 0x00 (NUL byte)
    return (input:gsub("^[%c%s%z]+", ""):gsub("[%c%s%z]+$", ""))
end

local function send_with_context(ctx, port, command, terminator_patterns)
    terminator_patterns = terminator_patterns or TERMINATOR_DEFAULTS
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

        for _, terminator_pattern in ipairs(terminator_patterns) do
            if line:find(terminator_pattern) then
                reader:close()
                return res, nil
            end
        end

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

        if #line > 0 then table.insert(res, line) end
    end
end

local function listen(port)
    return file.open(port, "r")
end

return {
    send_with_context = send_with_context,
    listen = listen,
    trim = trim,
}
