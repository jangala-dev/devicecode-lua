local file = require "fibers.stream.file"

local function extract_channel(line)
    local chan, freq, width, center1 = line:match(
        "%s*channel%s+(%d+)%s+%(([%d%s]+)MHz%)%s*,%s*width:%s*([%d%s]+)MHz,%s*center1:%s*([%d%s]+)MHz"
    )
    if chan and freq and width and center1 then
        return {
            chan = tonumber(chan),
            freq = tonumber(freq),
            width = tonumber(width),
            center1 = tonumber(center1)
        }
    end
    return nil
end

--- Convert a string output of the 'iw dev <interface> info' command into a lua table
--- @param raw_output string The string output from the 'iw dev <interface> info' command
--- @return table?
--- @return string? error
local function format_iw_dev_info(raw_output)
    if not raw_output or raw_output == "" then
        return nil, "No input provided"
    end

    local result = {}
    local lines = {}

    -- Split the output into lines
    for line in raw_output:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    -- Extract interface name from the first line
    result.interface = lines[1]:match("Interface%s+(.+)")
    if not result.interface then
        return nil, "Failed to parse interface name"
    end

    local i = 2 -- Start from the second line
    while i <= #lines do
        local line = lines[i]

        -- Handle multicast TXQ section
        if line:match("%s*multicast TXQ:") then
            local multicast = {}
            result.multicast = multicast

            -- Next line should contain headers
            if i + 1 <= #lines then
                local headers = {}
                for header in lines[i + 1]:gsub("^%s+", ""):gmatch("%S+") do
                    table.insert(headers, header)
                end

                -- Line after headers should contain values
                if i + 2 <= #lines then
                    -- Parse the line once and extract all values
                    local values = {}
                    for value in lines[i + 2]:gsub("^%s+", ""):gmatch("%S+") do
                        table.insert(values, value)
                    end

                    -- Now associate each header with its corresponding value
                    for j, header in ipairs(headers) do
                        if values[j] then
                            multicast[header] = tonumber(values[j]) or values[j]
                        end
                    end
                end
                i = i + 2 -- Skip the headers and values lines
            end
            -- Handle regular key-value pairs
        else
            if line:match("%s*ifindex%s+(%d+)") then
                result.ifindex = tonumber(line:match("%s*ifindex%s+(%d+)"))
            elseif line:match("%s*wdev%s+(%x+)") then
                result.wdev = line:match("%s*wdev%s+(%x+)")
            elseif line:match("%s*addr%s+([%x:]+)") then
                result.addr = line:match("%s*addr%s+([%x:]+)")
            elseif line:match("%s*ssid%s+(.+)") then
                result.ssid = line:match("%s*ssid%s+(.+)")
            elseif line:match("%s*type%s+(%S+)") then
                result.type = line:match("%s*type%s+(%S+)")
            elseif line:match("%s*wiphy%s+(%d+)") then
                result.wiphy = tonumber(line:match("%s*wiphy%s+(%d+)"))
            elseif line:match("%s*txpower%s+([%d.]+)%s+dBm") then
                result.txpower = tonumber(line:match("%s*txpower%s+([%d.]+)%s+dBm"))
            elseif line:match("%s*channel") then
                result.channel = extract_channel(line)
            end
        end

        i = i + 1
    end

    return result, nil
end

--- Parse the output of "iw dev <interface> station get <mac>" into a structured table
--- @param raw_output string The raw output from the iw command
--- @return table Parsed station information
local function format_iw_client_info(raw_output)
    local result = {}

    -- Process each line
    for line in raw_output:gmatch("[^\r\n]+") do
        -- Skip the header line
        if not line:match("^Station") then
            -- Extract key and value
            local key, value = line:match("^%s+([^:]+):%s+(.+)$")

            if key and value then
                -- Clean up key name: convert spaces to underscores and lowercase
                key = key:gsub("%s+", "_"):lower()

                -- Handle special case for associated at [boottime]
                if key == "associated_at_[boottime]" then
                    local boottime = value:match("(%d+%.%d+)s")
                    result["associated_at_boottime"] = tonumber(boottime)
                    -- Handle bitrates (e.g. "6.0 MBit/s")
                elseif value:match("^%-?%d+%.%d+%s+%w+/s$") then
                    local num, unit = value:match("^(%-?%d+%.%d+)%s+(.+)")
                    result[key] = tonumber(num)
                    result[key .. "_unit"] = unit
                    -- Handle signal with range (e.g. "-33 [-36, -35] dBm")
                elseif value:match("^%-?%d+%s+%[") then
                    local main = value:match("^(%-?%d+)")
                    result[key] = tonumber(main)
                    -- Handle values with units (e.g. "1390 ms")
                elseif value:match("^%-?%d+%s+%w+$") then
                    local num, unit = value:match("^(%-?%d+)%s+(.+)")
                    result[key] = tonumber(num)
                    result[key .. "_unit"] = unit
                    -- Handle integer values
                elseif value:match("^%-?%d+$") then
                    result[key] = tonumber(value)
                    -- Handle boolean-like values
                elseif value == "yes" or value == "no" then
                    result[key] = value
                    -- Handle associated timestamp
                elseif key == "associated_at" or key == "current_time" then
                    result[key] = tonumber(value:match("(%d+)"))
                    -- Default case: keep as string
                else
                    result[key] = value
                end
            end
        end
    end

    return result
end

local function get_net_statistic(interface, statistic)
    local filedata, file_err = file.open("/sys/class/net/" .. interface .. "/statistics/" .. statistic, "r")
    if file_err then
        return nil, file_err
    end
    local content, content_err = filedata:read_all_chars()
    if content_err then
        return nil, content_err
    end

    filedata:close()

    local num = tonumber(string.match(content or "", "(%d+)"))
    if num == nil then return nil, statistic .. " invalid number" end

    return num, nil
end

local function parse_dev_noise(raw_output)
    if not raw_output or raw_output == "" then
        return nil, "No input provided"
    end

    local in_use_section = false

    for line in raw_output:gmatch("[^\r\n]+") do
        if not in_use_section then
            if line:find("%[in use%]") then
                in_use_section = true
            end
        else
            if line:find("noise:") then
                local value = line:match("noise:%s*([%-]?%d+%.?%d*)")
                if value then
                    return tonumber(value), nil
                end
                return nil, "Noise value missing"
            end
        end
    end

    return nil, "Noise value not found"
end

return {
    format_iw_dev_info = format_iw_dev_info,
    format_iw_client_info = format_iw_client_info,
    get_net_statistic = get_net_statistic,
    parse_dev_noise = parse_dev_noise
}
