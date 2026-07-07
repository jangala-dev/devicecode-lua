-- services/metrics/state_projection.lua
--
-- Transitional mapping table for the future metrics pipeline.
--
-- The intended direction is for metrics to observe retained domain /state and
-- derive gauges/counters from that public model, rather than requiring each
-- service to actively publish UI-critical operational facts as metrics.

return {
    {
        topic = { 'state', 'system', 'stats' },
        metrics = {
            { path = { 'cpu', 'utilisation' }, name = 'system.cpu_util' },
            { path = { 'memory', 'utilisation' }, name = 'system.mem_util' },
            { path = { 'thermal', 'zone0', 'temp_c' }, name = 'system.temp' },
        },
    },
    {
        topic = { 'state', 'net', 'backhaul' },
        metrics = {
            -- Future projection: per-uplink availability, usable state and uptime.
        },
    },
    {
        topic = { 'state', 'gsm', 'uplink', '+' },
        metrics = {
            -- Future projection: cellular connectivity and SIM state.
        },
    },
}
