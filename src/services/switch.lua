local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'
local log = require 'services.log'
local new_msg = require('bus').new_msg

local switch_service = {
    name = "switch"
}
switch_service.__index = switch_service

local function load_driver(switch_type)
    local ok, driver = pcall(require, "services.switch." .. switch_type)
    if not ok then
        return nil, "Unsupported switch type: " .. tostring(switch_type)
    end
    return driver, nil
end

local function collect_metrics(ctx, bus_connection)
    local sub_switch = bus_connection:subscribe({ "config", "switch" })

    op.choice(
        sub_switch:next_msg_op():wrap(function(msg)
            log.trace("Switch: Config received")
            local cfg = msg.payload
            -- TODO: Should make driver global
            local driver, err = load_driver(cfg.type)

            if err or not driver then
                log.error("Switch: Error loading driver:", err)
                return
            end

            -- TODO: Probably don't auth here. Should load driver. Auth. And then globally accessible
            -- Unsure how to re-auth currently
            driver.login(cfg.host, cfg.username, cfg.password)

            while true do
                log.trace("Switch: Collecting metrics")
                local stats, err = driver.get_stats(cfg.host)

                if err then
                    log.error("Switch: Error getting stats:", err)
                    break
                end

                -- TODO: How do we want to publish messages to bus?
                bus_connection:publish(new_msg({ 'switch' }, stats, { retained = true }))

                sleep.sleep(cfg.report_period)
            end
        end),
        ctx:done_op()
    ):perform()
end

function switch_service:start(ctx, bus_connection)
    log.trace("Starting Switch Service")

    self.bus_connection = bus_connection

    fiber.spawn(function()
        collect_metrics(ctx, bus_connection)
    end)
end

return switch_service
