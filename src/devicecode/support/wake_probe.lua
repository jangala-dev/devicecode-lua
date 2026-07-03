-- devicecode/support/wake_probe.lua
--
-- Lightweight wake-rate instrumentation for cooperative services.  It is disabled
-- unless explicitly enabled via opts.wake_probe or DEVICECODE_WAKE_PROBE=1.
-- Probes aggregate in memory for a short interval, then publish one retained
-- obs/v1/<service>/metric/wake_probe payload.  They do not retain event history.

local runtime = require 'fibers.runtime'

local M = {}
local Probe = {}
Probe.__index = Probe

local function env_truthy(name)
    local v = os.getenv(name)
    if v == nil or v == '' then return false end
    v = tostring(v):lower()
    return not (v == '0' or v == 'false' or v == 'no' or v == 'off')
end

local function number_opt(v, default)
    local n = tonumber(v)
    if n == nil then return default end
    return n
end

local function bool_opt(v, default)
    if v == nil then return default end
    if type(v) == 'boolean' then return v end
    local s = tostring(v):lower()
    if s == '1' or s == 'true' or s == 'yes' or s == 'on' then return true end
    if s == '0' or s == 'false' or s == 'no' or s == 'off' then return false end
    return default
end

function M.enabled(opts)
    opts = opts or {}
    if opts.wake_probe ~= nil then return bool_opt(opts.wake_probe, false) end
    if opts.wake_probe_enabled ~= nil then return bool_opt(opts.wake_probe_enabled, false) end
    return env_truthy('DEVICECODE_WAKE_PROBE')
end

local function event_detail(ev)
    if type(ev) ~= 'table' then return tostring(ev) end
    return tostring(ev.kind or ev.type or ev.what or ev.source or ev.event or 'table')
end

local function add_top(out, key, count, elapsed)
    out[#out + 1] = {
        key = key,
        count = count,
        rate_per_s = elapsed > 0 and (count / elapsed) or count,
    }
end

local function sort_top(top)
    table.sort(top, function (a, b)
        if a.count ~= b.count then return a.count > b.count end
        return tostring(a.key) < tostring(b.key)
    end)
end

function M.new(svc, opts)
    opts = opts or {}
    local enabled = M.enabled(opts)
    local now = runtime.now()
    return setmetatable({
        enabled = enabled,
        svc = svc,
        conn = opts.conn or (svc and svc.conn),
        service = opts.service or (svc and svc.name) or opts.name or 'service',
        name = opts.metric_name or opts.wake_probe_metric or 'wake_probe',
        report_interval_s = number_opt(opts.report_interval_s or os.getenv('DEVICECODE_WAKE_PROBE_INTERVAL_S'), 10.0),
        warn_rate_per_s = number_opt(opts.warn_rate_per_s or os.getenv('DEVICECODE_WAKE_PROBE_WARN_RATE'), 0),
        max_top = math.max(1, math.floor(number_opt(opts.max_top or os.getenv('DEVICECODE_WAKE_PROBE_TOP'), 16))),
        counts = {},
        total = 0,
        since = now,
        next_report = now + math.max(1.0, number_opt(opts.report_interval_s or os.getenv('DEVICECODE_WAKE_PROBE_INTERVAL_S'), 10.0)),
    }, Probe)
end

function Probe:active()
    return self.enabled == true
end

function Probe:record(source, detail, n)
    if self.enabled ~= true then return false end
    source = tostring(source or 'wake')
    local key = detail ~= nil and (source .. ':' .. tostring(detail)) or source
    n = tonumber(n) or 1
    if n <= 0 then return false end
    self.counts[key] = (self.counts[key] or 0) + n
    self.total = self.total + n
    return true
end

function Probe:record_event(source, ev)
    if self.enabled ~= true then return false end
    return self:record(source, event_detail(ev), 1)
end

function Probe:record_choice(which, ev)
    if self.enabled ~= true then return false end
    return self:record(tostring(which or 'choice'), event_detail(ev), 1)
end

function Probe:report_if_due(extra)
    if self.enabled ~= true then return false end
    local now = runtime.now()
    if now < self.next_report then return false end

    local elapsed = now - self.since
    if elapsed <= 0 then elapsed = 0.000001 end

    local top = {}
    for key, count in pairs(self.counts) do add_top(top, key, count, elapsed) end
    sort_top(top)
    while #top > self.max_top do top[#top] = nil end

    local payload = {
        service = self.service,
        interval_s = elapsed,
        total_wakes = self.total,
        rate_per_s = self.total / elapsed,
        top = top,
    }
    if type(extra) == 'table' then
        for k, v in pairs(extra) do payload[k] = v end
    end

    if self.svc and type(self.svc.obs_metric) == 'function' then
        self.svc:obs_metric(self.name, payload)
    elseif self.conn and type(self.conn.retain) == 'function' then
        self.conn:retain({ 'obs', 'v1', self.service, 'metric', self.name }, payload)
    elseif self.svc and type(self.svc.obs_log) == 'function' then
        self.svc:obs_log('debug', payload)
    end

    if self.warn_rate_per_s > 0 and payload.rate_per_s >= self.warn_rate_per_s
        and self.svc and type(self.svc.obs_log) == 'function' then
        local warn_payload = {}
        for k, v in pairs(payload) do warn_payload[k] = v end
        warn_payload.what = 'wake_probe_high_rate'
        self.svc:obs_log('warn', warn_payload)
    end

    self.counts = {}
    self.total = 0
    self.since = now
    self.next_report = now + math.max(1.0, self.report_interval_s)
    return true
end

function Probe:record_and_report(source, detail, extra)
    self:record(source, detail, 1)
    return self:report_if_due(extra)
end

M.Probe = Probe
return M
