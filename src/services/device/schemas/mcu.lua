local topics = require 'services.device.topics'
local model = require 'services.device.model'

local M = {}

M.alert_kinds = {
  vin_lo = true,
  vin_hi = true,
  bsr_high = true,
  bat_missing = true,
  bat_short = true,
  max_charge_time_fault = true,
  absorb = true,
  equalize = true,
  cccv = true,
  precharge = true,
  iin_limited = true,
  uvcl_active = true,
  cc_phase = true,
  cv_phase = true,
}

function M.member_fact_topics(member)
  member = member or 'mcu'
  return {
    software = topics.member_state(member, 'software'),
    updater = topics.member_state(member, 'updater'),
    health = topics.member_state(member, 'health'),
    power_battery = topics.member_state(member, 'power', 'battery'),
    power_charger = topics.member_state(member, 'power', 'charger'),
    power_charger_config = topics.member_state(member, 'power', 'charger', 'config'),
    environment_temperature = topics.member_state(member, 'environment', 'temperature'),
    environment_humidity = topics.member_state(member, 'environment', 'humidity'),
    runtime_memory = topics.member_state(member, 'runtime', 'memory'),
  }
end

function M.member_event_topics(member)
  member = member or 'mcu'
  return {
    charger_alert = topics.member_event(member, 'power', 'charger', 'alert'),
  }
end

local function table_or_empty(v)
  return type(v) == 'table' and v or {}
end

local function copy(v)
  return model.copy_value(v)
end

local function number_or_nil(v)
  return type(v) == 'number' and v or nil
end

local function bool_or_nil(v)
  return type(v) == 'boolean' and v or nil
end

local function copy_named(raw, names)
  local out = {}
  raw = table_or_empty(raw)
  for i = 1, #names do
    local name = names[i]
    if raw[name] ~= nil then out[name] = raw[name] end
  end
  return out
end

function M.normalize_software(raw)
  raw = table_or_empty(raw)
  return {
    version = raw.version or raw.fw_version or nil,
    build = raw.build or raw.build_id or nil,
    image_id = raw.image_id or nil,
    boot_id = raw.boot_id or nil,
    payload_sha256 = raw.payload_sha256 or nil,
  }
end

function M.normalize_updater(raw)
  raw = table_or_empty(raw)
  return {
    state = raw.state or raw.status or raw.kind or nil,
    last_error = raw.last_error or raw.err or nil,
    pending_version = raw.pending_version or nil,
  }
end

function M.normalize_health(raw)
  raw = table_or_empty(raw)
  if raw.state ~= nil then return raw.state end
  if raw.health ~= nil then return raw.health end
  if next(raw) ~= nil then return 'ok' end
  return nil
end

function M.normalize_battery(raw)
  raw = table_or_empty(raw)
  return copy_named(raw, {
    'pack_mV', 'per_cell_mV', 'ibat_mA', 'temp_mC', 'bsr_uohm_per_cell', 'seq', 'uptime_ms',
  })
end

function M.normalize_charger(raw)
  raw = table_or_empty(raw)
  local out = copy_named(raw, {
    'vin_mV', 'vsys_mV', 'iin_mA', 'state_bits', 'status_bits', 'system_bits', 'seq', 'uptime_ms',
  })
  if type(raw.state) == 'table' then out.state = copy(raw.state) end
  if type(raw.status) == 'table' then out.status = copy(raw.status) end
  if type(raw.system) == 'table' then out.system = copy(raw.system) end
  return out
end

function M.normalize_charger_config(raw)
  raw = table_or_empty(raw)
  local out = {
    schema = raw.schema,
    source = raw.source,
    alert_mask_bits = raw.alert_mask_bits,
    seq = raw.seq,
    uptime_ms = raw.uptime_ms,
  }
  if type(raw.thresholds) == 'table' then
    out.thresholds = copy_named(raw.thresholds, { 'vin_lo_mV', 'vin_hi_mV', 'bsr_high_uohm_per_cell' })
  end
  if type(raw.alert_mask) == 'table' then
    out.alert_mask = {}
    for kind in pairs(M.alert_kinds) do
      local v = bool_or_nil(raw.alert_mask[kind])
      if v ~= nil then out.alert_mask[kind] = v end
    end
  end
  return out
end

function M.normalize_temperature(raw)
  raw = table_or_empty(raw)
  return copy_named(raw, { 'deci_c', 'seq', 'uptime_ms' })
end

function M.normalize_humidity(raw)
  raw = table_or_empty(raw)
  return copy_named(raw, { 'rh_x100', 'seq', 'uptime_ms' })
end

function M.normalize_runtime_memory(raw)
  raw = table_or_empty(raw)
  return copy_named(raw, { 'alloc_bytes', 'seq', 'uptime_ms' })
end

function M.normalize_charger_alert(raw)
  raw = table_or_empty(raw)
  local kind = raw.kind
  return {
    kind = type(kind) == 'string' and kind or nil,
    known = type(kind) == 'string' and M.alert_kinds[kind] == true or false,
    severity = raw.severity,
    source = raw.source,
    state_bits = number_or_nil(raw.state_bits),
    status_bits = number_or_nil(raw.status_bits),
    system_bits = number_or_nil(raw.system_bits),
    seq = raw.seq,
    uptime_ms = raw.uptime_ms,
  }
end

return M
