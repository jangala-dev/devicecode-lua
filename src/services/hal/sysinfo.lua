local file = require "fibers.stream.file"
local sleep = require "fibers.sleep"
local op = require "fibers.op"
local exec = require "fibers.exec"
local utils = require "services.hal.utils"

---@return string?
---@return string? Error
local function get_cpu_info(_)
    local cpuinfo, cpuinfo_err = utils.read_file("/proc/cpuinfo")
    if cpuinfo_err or not cpuinfo then return nil, cpuinfo_err end
    local model

    if cpuinfo:match("Qualcomm Atheros") then
        model = cpuinfo:match("cpu model%s+:%s+(.+)\n")
    elseif cpuinfo:match("Raspberry Pi") then
        model = "Raspberry Pi 4 Model B"
    else
        model = "Unknown"
    end

    return model, nil
end

---@param ctx Context
---@return table? cpu_utilisation_and_freq
---@return string? Error
local function get_cpu_utilisation_and_freq(ctx)
    local function extract_cpu_times(stat, core)
        local pattern = core .. "%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)"
        local user, nice, system, idle = stat:match(pattern)
        return tonumber(user), tonumber(nice), tonumber(system), tonumber(idle)
    end

    local function compute_utilisation(user_prev, nice_prev, system_prev, idle_prev, user_curr, nice_curr, system_curr, idle_curr)
        local total_prev = user_prev + nice_prev + system_prev + idle_prev
        local total_curr = user_curr + nice_curr + system_curr + idle_curr
        local active_diff = (user_curr - user_prev) + (nice_curr - nice_prev) + (system_curr - system_prev)
        local total_diff = total_curr - total_prev
        return total_diff == 0 and 0 or (active_diff / total_diff) * 100
    end

    local function get_scaling_cur_freq(core)
        local path = "/sys/devices/system/cpu/" .. core .. "/cpufreq/scaling_cur_freq"
        local freq, read_err = utils.read_file(path)
        if not freq or read_err then return nil, read_err end
        return tonumber(freq), nil
    end

    local stat_prev, prev_err = utils.read_file("/proc/stat")
    if prev_err then return nil, prev_err end
    local ctx_err = op.choice(
        sleep.sleep_op(1),
        ctx:done_op():wrap(function ()
            return ctx:err()
        end)
    ):perform()
    if ctx_err then return nil, ctx_err end
    local stat_curr, curr_err = utils.read_file("/proc/stat")
    if curr_err then return nil, curr_err end

    local core_utilisations = {}
    local core_frequencies = {}
    local core_id = 0
    local overall_utilisation_sum = 0
    local overall_freq_sum = 0

    while true do
        local core = "cpu" .. core_id
        local user_prev, nice_prev, system_prev, idle_prev = extract_cpu_times(stat_prev, core)
        if not user_prev then
            break
        end
        local user_curr, nice_curr, system_curr, idle_curr = extract_cpu_times(stat_curr, core)
        local utilisation = compute_utilisation(user_prev, nice_prev, system_prev, idle_prev, user_curr, nice_curr, system_curr, idle_curr)
        core_utilisations[core] = utilisation
        overall_utilisation_sum = overall_utilisation_sum + utilisation

        local freq = get_scaling_cur_freq(core)
        if freq then
            core_frequencies[core] = freq
            overall_freq_sum = overall_freq_sum + freq
        end

        core_id = core_id + 1
    end

    local overall_utilisation = overall_utilisation_sum / (core_id > 0 and core_id or 1)
    local average_frequency = overall_freq_sum / (core_id > 0 and core_id or 1)

    return {
        overall_utilisation = overall_utilisation,
        core_utilisations = core_utilisations,
        average_frequency = average_frequency,
        core_frequencies = core_frequencies
    }
end

--- Get total, used, and free RAM
---@return table? ram_info
---@return string? Error
local function get_ram_info(_)
    local meminfo, err = utils.read_file("/proc/meminfo")
    if not meminfo or err then return nil, err end
    local total = meminfo:match("MemTotal:%s*(%d+)") or 0
    local free = meminfo:match("MemFree:%s*(%d+)") or 0
    local buffers = meminfo:match("Buffers:%s*(%d+)") or 0
    local cached = meminfo:match("Cached:%s*(%d+)") or 0

    local used = total - (free + buffers + cached)
    return {
        total = tonumber(total),
        used = tonumber(used),
        free = tonumber(free) + tonumber(buffers) + tonumber(cached)
    }, nil
end

---Gets the modem and version of hardware
---@return string? model
---@return string? version
---@return string? error
local function get_hw_revision(_)
    local revision, err = utils.read_file("/etc/hwrevision")
    if err or not revision then return nil, nil, err end
    return revision, nil
end

---@return string? version
---@return string? error
local function get_fw_version(_)
    local version, err = utils.read_file("/etc/fwversion")
    if err or not version then return nil, err end
    return version, nil
end

local function get_serial(_)
    local serial, err = utils.read_file("/data/serial")
    if err or not serial then return nil, err end
    return serial, nil
end

local function get_temperature(_)
    local temperature, err = utils.read_file("/sys/class/thermal/thermal_zone0/temp")
    if err or not temperature then return nil, err end
    return tonumber(temperature) / 1000, nil
end

local function get_uptime(_)
    local uptime, err = utils.read_file("/proc/uptime")
    if err or not uptime then return nil, err end
    local up = string.match(uptime, "(%S+)%s")
    if not up then return nil, "Failed to parse uptime" end
    return tonumber(up), nil
end

local function get_board_revision(_)
    local board_revision_data, err = exec.command("fw_printenv"):output()
    if err then
        return nil, err
    end
    local board_revision = string.match(board_revision_data, "board_revision=([^\n]+)")
    return board_revision, nil
end

return {
    get_hw_revision = get_hw_revision,
    get_fw_version = get_fw_version,
    get_cpu_model = get_cpu_info,
    get_cpu_utilisation_and_freq = get_cpu_utilisation_and_freq,
    get_ram_info = get_ram_info,
    get_serial = get_serial,
    get_temperature = get_temperature,
    get_uptime = get_uptime,
    get_board_revision = get_board_revision
}
