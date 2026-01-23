local exec = require "fibers.exec"
local cjson = require "cjson.safe"

local Ubus = {}

-- Context-free variants
function Ubus.list(...)
    return exec.command('ubus', 'list', ...)
end

function Ubus.call(path, method, ...)
    return exec.command('ubus', 'call', path, method, ...)
end

function Ubus.listen(...)
    return exec.command('ubus', 'listen', ...)
end

function Ubus.send(type, message)
    local encoded_message = cjson.encode(message)
    return exec.command('ubus', 'send', type, encoded_message)
end

-- Context-aware variants
function Ubus.list_with_context(ctx, ...)
    return exec.command_context(ctx, 'ubus', 'list', ...)
end

function Ubus.call_with_context(ctx, path, method, ...)
    return exec.command_context(ctx, 'ubus', 'call', path, method, ...)
end

function Ubus.listen_with_context(ctx, ...)
    return exec.command_context(ctx, 'ubus', 'listen', ...)
end

function Ubus.send_with_context(ctx, type, message)
    local encoded_message = cjson.encode(message)
    return exec.command_context(ctx, 'ubus', 'send', type, encoded_message)
end

return Ubus
