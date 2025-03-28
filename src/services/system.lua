local function read_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function get_cpu_info()
    local cpuinfo = assert(read_file("/proc/cpuinfo"))
    local model

    if cpuinfo:match("Qualcomm Atheros") then
        model = cpuinfo:match("cpu model%s+:%s+(.+)\n")
    elseif cpuinfo:match("Raspberry Pi") then
        model = "Raspberry Pi 4 Model B"
    else
        model = "Unknown"
    end

    return model
end

local function get_cpu_utilisation_and_freq()
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
        local freq = read_file(path)
        return freq and tonumber(freq) or nil
    end

    local stat_prev = read_file("/proc/stat")
    os.execute("sleep 1")
    local stat_curr = read_file("/proc/stat")

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

    return overall_utilisation, core_utilisations, average_frequency, core_frequencies
end    

-- Get total, used, and free RAM
local function get_ram_info()
    local meminfo = assert(read_file("/proc/meminfo"))
    local total = meminfo:match("MemTotal:%s*(%d+)") or 0
    local free = meminfo:match("MemFree:%s*(%d+)") or 0
    local buffers = meminfo:match("Buffers:%s*(%d+)") or 0
    local cached = meminfo:match("Cached:%s*(%d+)") or 0

    local used = total - (free + buffers + cached)
    return total, used, free + buffers + cached
end

local function main()
    -- local cpu_model = get_cpu_info()
    local ram_total, ram_used, ram_free = get_ram_info()

    local overall_utilisation, core_utilisations, average_frequency, core_frequencies = get_cpu_utilisation_and_freq()

    -- print("CPU Info: " .. cpu_model)
    print("Overall CPU Utilisation:", overall_utilisation .. "%")
    print("Average Frequency:", average_frequency .. "kHz")
    for core, util in pairs(core_utilisations) do
        print(core .. " Utilisation:", util .. "%")
        print(core .. " Frequency:", (core_frequencies[core] or "Unknown"))
    end
    print("Total RAM: " .. ram_total .. " kB")
    print("Used RAM: " .. ram_used .. " kB")
    print("Free RAM: " .. ram_free .. " kB")
end

main()