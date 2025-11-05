local fiber = require "fibers.fiber"
local sleep = require "fibers.sleep"
local context = require "fibers.context"
local op = require "fibers.op"
local log = require "services.log"
local new_msg = require("bus").new_msg

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

local function handler(ctx, bus_connection)
    local sub_switch = bus_connection:subscribe({ "config", "switch" })
    local stats_ctx = nil
    local cancel_stats = nil

    while ctx:err() == nil do
        op.choice(
            sub_switch:next_msg_op():wrap(function(msg)
                log.trace("Switch: Config received")
                local cfg = msg.payload
                local driver, err = load_driver(cfg.type)

                if err or not driver then
                    log.error("Switch: Error loading driver:", err)
                    return
                end

                -- cancel any running stats loop
                if cancel_stats then cancel_stats("new config") end

                -- create a fresh child context for stats
                stats_ctx, cancel_stats = context.with_cancel(ctx)

                fiber.spawn(function()
                    log.trace("Switch: Starting login")
                    local ok, err = driver.login(cfg.host, cfg.username, cfg.password)

                    if not ok then
                        -- TODO no retry here
                        log.error("Switch: Initial login failed:", err)
                        return
                    end

                    log.trace("Switch: Login successful")

                    local fail_count = 0
                    local max_fails = 5

                    while stats_ctx:err() == nil do
                        log.trace("Switch: Collecting metrics")
                        local stats, err = driver.get_stats(cfg.host)

                        if err then
                            fail_count = fail_count + 1
                            log.error("Switch: Stats error (fail " .. fail_count .. "):", err)

                            if fail_count >= max_fails then
                                log.warn("Switch: Too many failures, retrying login")
                                local ok, lerr = driver.login(cfg.host, cfg.username, cfg.password)
                                if not ok then
                                    log.error("Switch: Re-login failed:", lerr)
                                    break
                                end
                                fail_count = 0
                            end

                            sleep.sleep(5)
                        else
                            log.trace("Switch: Publishing stats")
                            fail_count = 0 -- reset on success
                            bus_connection:publish_multiple({ "switch" }, stats, { retained = true })
                            sleep.sleep(cfg.report_period or 10)
                        end
                    end
                end)
            end),
            ctx:done_op()
        ):perform()
    end
end

function switch_service:start(ctx, bus_connection)
    log.trace("Starting Switch Service")

    self.bus_connection = bus_connection

    fiber.spawn(function()
        handler(ctx, bus_connection)
    end)
end

return switch_service
