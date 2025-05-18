local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local file = require 'fibers.stream.file'
local exec = require 'fibers.exec'
local sc = require 'fibers.utils.syscall'
local log = require "log"
local context = require "fibers.context"


local DOWNLOAD_URL = "https://proof.ovh.net/files/100Mb.dat"
local SAMPLE_INTERVAL = 0.06     -- 60ms between measurements
local NO_IMPROVEMENT_SAMPLES = 2 -- Number of consecutive samples with no improvement before stopping
local STARTUP_TIMEOUT = 2        -- Seconds to wait for connection to speedtest server

local function run(ctx, owrt_interface, linux_interface)
    local cmd = exec.command('mwan3', 'use', owrt_interface, 'wget', '-O', '/dev/null', DOWNLOAD_URL)
    cmd:setpgid(true)
    local stderr_pipe = assert(cmd:stderr_pipe())

    local err = cmd:start()
    if err then return nil, "Failed to start wget" end

    local rx_file = file.open("/sys/class/net/" .. linux_interface .. "/statistics/rx_bytes", "r")
    if not rx_file then return nil, "Failed to open RX bytes" end

    local function get_rx_bytes()
        rx_file:seek(0)  -- Rewind to beginning
        return tonumber(rx_file:read_all_chars())
    end

    local started = false
    local ctx_timeout

    -- Detect the moment the download begins
    while true do
        ctx_timeout = context.with_timeout(ctx, STARTUP_TIMEOUT)
        local line = op.choice(
            stderr_pipe:read_line_op(),
            -- stderr_pipe:read_some_chars_op(),
            ctx_timeout:done_op()
        ):perform()
        if not line then break end

        if line:find("Writing to") then
            log.debug("NET: speedtest started!")
            started = true
            break
        end
    end
    stderr_pipe:close()

    if not started then
        rx_file:close()
        cmd:kill()
        cmd:wait()
        return nil, ctx:err() or ctx_timeout:err() or "Could not start file download"
    end

    -- Capture initial bytes/time
    local start_time = sc.monotime()
    local start_bytes = get_rx_bytes()
    if not start_bytes then
        rx_file:close()
        cmd:kill()
        cmd:wait()
        return nil,  "Failed to read RX bytes"
    end

    -- Set up a measurement loop
    local prev_time = start_time
    local prev_bytes = start_bytes

    local peak_speed = 0
    local consecutive_no_improvement = 0

    while not ctx:err() do
        sleep.sleep(SAMPLE_INTERVAL)

        local now = sc.monotime()
        local current_bytes = get_rx_bytes()
        if not current_bytes then
            break
        end

        local elapsed = now - prev_time
        local diff = current_bytes - prev_bytes
        local speed_mbps = (diff * 8) / (elapsed * 2 ^ 20)

        -- Update peak speed or increment the no-improvement counter
        if speed_mbps > peak_speed then
            peak_speed = speed_mbps
            consecutive_no_improvement = 0
        else
            consecutive_no_improvement = consecutive_no_improvement + 1
        end

        prev_time = now
        prev_bytes = current_bytes

        -- If we've had too many consecutive samples without beating the peak, stop
        if consecutive_no_improvement >= NO_IMPROVEMENT_SAMPLES then
            break
        end
    end

    -- Stop the command
    rx_file:close()
    cmd:kill()
    cmd:wait()

    if ctx:err() then return nil, ctx:err() end

    return {
        peak = peak_speed,
        data = (prev_bytes - start_bytes) / 2 ^ 20,
        time = prev_time - start_time
    }, nil
end

return {
    run = run
}
