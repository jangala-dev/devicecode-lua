local model = require 'services.device.model'
local schema = require 'services.device.schemas.mcu'

local M = {}

local function copy(v)
  return model.copy_value(v)
end

local function table_or_empty(t)
  return type(t) == 'table' and t or {}
end

function M.compose(raw_facts, raw_events)
  raw_facts = type(raw_facts) == 'table' and raw_facts or {}
  raw_events = type(raw_events) == 'table' and raw_events or {}

  local software_raw = raw_facts.software
  local updater_raw = raw_facts.updater
  local health_raw = raw_facts.health
  local battery_raw = raw_facts.power_battery
  local charger_raw = raw_facts.power_charger
  local charger_config_raw = raw_facts.power_charger_config
  local temperature_raw = raw_facts.environment_temperature
  local humidity_raw = raw_facts.environment_humidity
  local memory_raw = raw_facts.runtime_memory
  local charger_alert_raw = raw_events.charger_alert

  local software = schema.normalize_software(software_raw)
  local updater = schema.normalize_updater(updater_raw)
  local health = schema.normalize_health(health_raw)
  local battery = schema.normalize_battery(battery_raw)
  local charger = schema.normalize_charger(charger_raw)
  local charger_config = schema.normalize_charger_config(charger_config_raw)
  local temperature = schema.normalize_temperature(temperature_raw)
  local humidity = schema.normalize_humidity(humidity_raw)
  local memory = schema.normalize_runtime_memory(memory_raw)
  local last_charger_alert = schema.normalize_charger_alert(charger_alert_raw)

  local alerts = {}
  if last_charger_alert.kind ~= nil then
    alerts.charger_alert = last_charger_alert
  end

  return {
    software = software,
    updater = updater,
    health = health,
    power = {
      battery = table_or_empty(battery),
      charger = table_or_empty(charger),
      charger_config = {
        schema = charger_config.schema,
        source = charger_config.source,
        alert_mask_bits = charger_config.alert_mask_bits,
        seq = charger_config.seq,
        uptime_ms = charger_config.uptime_ms,
        thresholds = table_or_empty(charger_config.thresholds),
        alert_mask = table_or_empty(charger_config.alert_mask),
      },
    },
    environment = {
      temperature = table_or_empty(temperature),
      humidity = table_or_empty(humidity),
    },
    runtime = {
      memory = table_or_empty(memory),
    },
    alerts = alerts,
    raw = {
      software = copy(software_raw),
      updater = copy(updater_raw),
      health = copy(health_raw),
      power_battery = copy(battery_raw),
      power_charger = copy(charger_raw),
      power_charger_config = copy(charger_config_raw),
      environment_temperature = copy(temperature_raw),
      environment_humidity = copy(humidity_raw),
      runtime_memory = copy(memory_raw),
    },
  }
end

return M
