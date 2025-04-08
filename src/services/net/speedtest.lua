local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local file = require 'fibers.stream.file'
local exec = require 'fibers.exec'
local sc = require 'fibers.utils.syscall'
local log = require "log"


local DOWNLOAD_URL = "https://proof.ovh.net/files/100Mb.dat"
local SAMPLE_INTERVAL = 0.07       -- 10ms between measurements
local NO_IMPROVEMENT_SAMPLES = 2  -- Number of consecutive samples with no improvement before stopping

local function run(ctx, owrt_interface, linux_interface)
    local cmd = exec.command('mwan3', 'use', owrt_interface, 'wget', '-O', '/dev/null', DOWNLOAD_URL)
    local stderr_pipe = assert(cmd:stderr_pipe())

    assert(cmd:start() == nil, "Failed to start wget")

    local rx_file = file.open("/sys/class/net/" .. linux_interface .. "/statistics/rx_bytes", "r")
    if not rx_file then return nil end

    local function get_rx_bytes()
        rx_file:seek(0)  -- Rewind to beginning
        return tonumber(rx_file:read_all_chars())
    end

    local started = false

    -- Detect the moment the download begins
    while true do
        local line = op.choice(
            stderr_pipe:read_some_chars_op(),
            ctx:done_op()
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
        return nil, ctx:err() or "Could not start file download"
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
    local speed_samples = {}  -- Store the last NO_IMPROVEMENT_SAMPLES speeds

    while not ctx:err() do
        sleep.sleep(SAMPLE_INTERVAL)

        local now = sc.monotime()
        local current_bytes = get_rx_bytes()
        if not current_bytes then
            break
        end

        local elapsed = now - prev_time
        local diff = current_bytes - prev_bytes
        local speed_mbps = (diff * 8) / (elapsed * 1e6)

        -- Update peak speed or increment the no-improvement counter
        if speed_mbps > peak_speed then
            peak_speed = speed_mbps
            consecutive_no_improvement = 0
        else
            consecutive_no_improvement = consecutive_no_improvement + 1
        end

        -- Maintain a sliding window of the last NO_IMPROVEMENT_SAMPLES speeds
        table.insert(speed_samples, speed_mbps)
        if #speed_samples > NO_IMPROVEMENT_SAMPLES then
            table.remove(speed_samples, 1) -- Keep only the latest N samples
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

    -- Compute the mean of the last NO_IMPROVEMENT_SAMPLES
    local sum = 0
    for _, speed in ipairs(speed_samples) do
        sum = sum + speed
    end
    local avg_recent_speed = sum / #speed_samples

    -- Compute the median of the last NO_IMPROVEMENT_SAMPLES
    table.sort(speed_samples)
    local n = #speed_samples
    local median_recent_speed
    if n % 2 == 1 then
        median_recent_speed = speed_samples[(n + 1) / 2]
    else
        median_recent_speed = (speed_samples[n / 2] + speed_samples[(n / 2) + 1]) / 2
    end

    return {
        mean = avg_recent_speed,
        median = median_recent_speed,
        peak = peak_speed,
        data = (prev_bytes - start_bytes) / 1e6,
        time = prev_time - start_time
    }, nil
end

return {
    run = run
}
