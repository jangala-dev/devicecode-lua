local M = {}

local function scaled(value, scale)
    if type(value) ~= 'number' then return nil end
    if scale == nil then return value end
    return value / scale
end

function M.from_legacy_sample(sample)
    if type(sample) ~= 'table' then return nil end
    local out = {
        available = true,
        ready = true,
        software = {},
        updater = {},
        source = { kind = 'legacy_uart_json' },
        raw = sample,
    }
    if sample['sys/mem/alloc'] ~= nil then
        out.health = 'ok'
        out.runtime = { alloc_bytes = sample['sys/mem/alloc'] }
    end
    if sample['env/temperature/core'] ~= nil or sample['env/humidity/core'] ~= nil then
        out.environment = {
            temperature_c = scaled(sample['env/temperature/core'], 100),
            humidity_rh = scaled(sample['env/humidity/core'], 100),
        }
    end
    if sample['power/battery/internal/vbat'] ~= nil or sample['power/battery/internal/ibat'] ~= nil then
        out.power = {
            battery = {
                voltage_v = scaled(sample['power/battery/internal/vbat'], 1000),
                current_a = scaled(sample['power/battery/internal/ibat'], 1000),
                bsr = sample['power/battery/internal/bsr'],
            },
        }
    end
    return out
end

return M
