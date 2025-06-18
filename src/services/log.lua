local rxilog = require 'rxilog'
local new_msg = require 'bus'.new_msg

local log_service = {
    name = "log",
}
log_service.__index = log_service

for _, mode in ipairs(rxilog.modes) do
    local level = mode.name
    log_service[level] = function(...)
        local msg = rxilog.tostring(...)
        rxilog[level](msg)

        if log_service.conn then
            local info = debug.getinfo(2, "Sl")
            local lineinfo = info.short_src .. ":" .. info.currentline
            local formatted_msg = rxilog.format_log_message(level:upper(), lineinfo, msg)

            log_service.conn:publish(new_msg({ "logs", level }, formatted_msg))
        end
    end
end

function log_service:start(ctx, conn)
    self.ctx = ctx
    self.conn = conn
    log_service.trace("Starting Log Service")
end

-- Make singleton
package.loaded["services.log"] = log_service
return log_service
