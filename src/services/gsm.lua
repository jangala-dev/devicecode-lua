-- services/gsm.lua
--
-- GSM service (new fibers):
--  - consumes HAL modem capabilities
--  - runs per-modem child scopes for autoconnect + metrics
--  - publishes derived observability metrics only

local fibers = require "fibers"
local op = require "fibers.op"
local sleep = require "fibers.sleep"
local pulse = require "fibers.pulse"

local perform = fibers.perform

local log = require "services.log"
local external_types = require "services.hal.types.external"

local REQUEST_TIMEOUT = 10
local DEFAULT_RETRY_TIMEOUT = 5
local DEFAULT_METRICS_INTERVAL = 10
local DEFAULT_SIGNAL_FREQ = 5

local SCOREMAP = {
	cdma1x = { rssi = { -110, -100, -86, -70, 1000000 } },
	evdo = { rssi = { -110, -100, -86, -70, 1000000 } },
	gsm = { rssi = { -110, -100, -86, -70, 1000000 } },
	umts = { rscp = { -124, -95, -85, -75, 1000000 } },
	lte = { rsrp = { -115, -105, -95, -85, 1000000 } },
	["5g"] = { rsrp = { -115, -105, -95, -85, 1000000 } },
}

local ACCESS_TECH_MAP = {
	{ tokens = { 'lte', '5gnr' }, tech = '5g' },
	{ tokens = { '5gnr' }, tech = '5g' },
	{ tokens = { '5g' }, tech = '5g' },
	{ tokens = { 'lte' }, tech = 'lte' },
	{ tokens = { 'umts' }, tech = 'umts' },
	{ tokens = { 'gsm' }, tech = 'gsm' },
	{ tokens = { 'evdo' }, tech = 'evdo' },
	{ tokens = { 'cdma1x' }, tech = 'cdma1x' },
}

---@return table
local function t(...)
	return { ... }
end

-- Topic helpers (centralized so we can remap if needed)
---@param name string
---@return table
local function t_cfg(name)
	return { 'cfg', name }
end

---@param id string|number
---@return table
local function t_cap_state(id)
	return { 'cap', 'modem', id, 'state' }
end

---@param id string|number
---@param method string
---@return table
local function t_cap_rpc(id, method)
	return { 'cap', 'modem', id, 'rpc', method }
end

---@param id string|number
---@param key string
---@return table
local function t_obs_metric(id, key)
	return { 'obs', 'v1', 'gsm', 'metric', id, key }
end

---@param id string|number
---@param key string
---@return table
local function t_obs_event(id, key)
	return { 'obs', 'v1', 'gsm', 'event', id, key }
end

---@param conn Connection
---@param name string
---@param state string
---@param extra table?
local function publish_status(conn, name, state, extra)
	local payload = { state = state, ts = fibers.now() }
	if type(extra) == 'table' then
		for k, v in pairs(extra) do payload[k] = v end
	end
	conn:retain(t('svc', name, 'status'), payload)
end

---@param conn Connection
---@param id string|number
---@param method string
---@param payload table?
---@param timeout number?
---@return any
---@return string
local function call_modem_rpc(conn, id, method, payload, timeout)
	local reply, err = conn:call(t_cap_rpc(id, method), payload or {}, {
		timeout = timeout or REQUEST_TIMEOUT,
	})
	if not reply then
		return false, err or "rpc failed"
	end
	if reply.ok ~= true then
		return false, reply.reason or 'rpc failed'
	end
	if reply.reason == nil then
		return false, "empty reply"
	end
	return reply.reason, ""
end

---@param conn Connection
---@param id string|number
---@param field string
---@param timeout number?
---@return any
---@return string
local function modem_get_field(conn, id, field, timeout)
	local opts, opts_err = external_types.new.ModemGetOpts(field)
	if not opts then
		return false, opts_err or "invalid modem get opts"
	end
	return call_modem_rpc(conn, id, 'get', opts, timeout)
end

---@param conn Connection
---@param id string|number
---@param freq number
---@return any
---@return string
local function modem_set_signal_freq(conn, id, freq)
	local opts, opts_err = external_types.new.ModemSignalUpdateOpts(freq)
	if not opts then
		return false, opts_err or "invalid signal update opts"
	end
	return call_modem_rpc(conn, id, 'set_signal_update_freq', opts, REQUEST_TIMEOUT)
end

---@param tbl table?
---@return table
local function shallow_copy(tbl)
	local out = {}
	if tbl then
		for k, v in pairs(tbl) do out[k] = v end
	end
	return out
end

---@param cfg table
---@param defaults table
local function apply_defaults(cfg, defaults)
	for key, value in pairs(defaults) do
		if cfg[key] == nil then
			cfg[key] = value
		elseif type(value) == 'table' and type(cfg[key]) == 'table' then
			apply_defaults(cfg[key], value)
		end
	end
end

---@param value any
---@return boolean
local function is_plain_table(value)
	return type(value) == 'table' and getmetatable(value) == nil
end

---@param access_techs any
---@return string
local function derive_access_tech(access_techs)
	local techs = {}
	if type(access_techs) == 'string' then
		for token in string.gmatch(access_techs, "([^,]+)") do
			techs[token] = true
		end
	elseif is_plain_table(access_techs) then
		for _, token in ipairs(access_techs) do
			techs[token] = true
		end
	end

	for _, rule in ipairs(ACCESS_TECH_MAP) do
		local all_match = true
		for _, required_token in ipairs(rule.tokens) do
			if not techs[required_token] then
				all_match = false
				break
			end
		end
		if all_match then
			return rule.tech
		end
	end

	return ""
end

---@param access_tech string
---@return string
local function get_access_family(access_tech)
	local map = {
		cdma1x = '3G',
		evdo = '3G',
		gsm = '2G',
		umts = '3G',
		lte = '4G',
		['5g'] = '5G',
	}
	return map[access_tech] or ""
end

---@param access_tech string
---@param signal_type string
---@param signal number
---@return number
---@return string
local function get_signal_bars(access_tech, signal_type, signal)
	local tech_map = SCOREMAP[access_tech]
	if not tech_map then
		return 0, "invalid access tech"
	end

	local thresholds = tech_map[signal_type]
	if not thresholds then
		return 0, "invalid signal type"
	end

	for index, threshold in ipairs(thresholds) do
		if signal < threshold then
			return index, ""
		end
	end

	return 0, ""
end

---@param sim_value any
---@return string
local function normalize_sim_presence(sim_value)
	if sim_value == nil or sim_value == '--' then
		return "--"
	end
	if type(sim_value) == 'table' then
		return "present"
	end
	if tostring(sim_value) ~= '' then
		return "present"
	end
	return "--"
end

---@param access_techs any
---@param access_err string
---@param rssi any
---@param rssi_err string
---@param rsrp any
---@param rsrp_err string
---@param rscp any
---@param rscp_err string
---@return string
---@return number
---@return string
local function select_signal_for_bars(access_techs, access_err, rssi, rssi_err, rsrp, rsrp_err, rscp, rscp_err)
	if access_err ~= "" then
		return "", 0, "access tech unavailable"
	end

	local access_tech = derive_access_tech(access_techs)
	if access_tech == "" then
		return "", 0, "access tech unknown"
	end

	if access_tech == 'umts' and rscp_err == "" then
		local rscp_value = tonumber(rscp)
		if rscp_value then
			return access_tech, rscp_value, "rscp"
		end
	end

	if (access_tech == 'lte' or access_tech == '5g') and rsrp_err == "" then
		local rsrp_value = tonumber(rsrp)
		if rsrp_value then
			return access_tech, rsrp_value, "rsrp"
		end
	end

	if rssi_err == "" then
		local rssi_value = tonumber(rssi)
		if rssi_value then
			return access_tech, rssi_value, "rssi"
		end
	end

	return access_tech, 0, ""
end

---@param cfg table?
---@return table
---@return string
local function normalize_config(cfg)
	if not is_plain_table(cfg) then
		return {}, "config must be a table"
	end
	---@cast cfg table
	local modems_cfg = rawget(cfg, 'modems')
	if not is_plain_table(modems_cfg) then
		return {}, "config.modems must be a table"
	end
	local modems_default = rawget(modems_cfg, 'default')
	if not is_plain_table(modems_default) then
		return {}, "config.modems.default must be a table"
	end
	local modems_known = rawget(modems_cfg, 'known')
	if modems_known ~= nil and type(modems_known) ~= 'table' then
		return {}, "config.modems.known must be a list"
	end
	return shallow_copy(cfg), ""
end

---@param cfg table
---@param imei string|number
---@param device string
---@return table
---@return string
---@return string
local function get_modem_config(cfg, imei, device)
	local base = shallow_copy(cfg.modems and cfg.modems.default or {})
	local known = cfg.modems and cfg.modems.known
	if type(known) == 'table' then
		for _, entry in ipairs(known) do
			if is_plain_table(entry) then
				local id_field = entry.id_field or 'imei'
				if (id_field == 'device' and device ~= "" and entry.device == device)
					or (id_field ~= 'device' and ((entry.imei == imei) or (entry.id == imei)))
				then
					local merged = shallow_copy(entry)
					apply_defaults(merged, base)
					return merged, (merged.name or ""), ""
				end
			end
		end
	end

	return base, "", ""
end

---@class GsmModem
---@field conn Connection
---@field id string|number
---@field name string
---@field cfg table
---@field device string
---@field scope Scope?
---@field config_pulse Pulse
local GsmModem = {}
GsmModem.__index = GsmModem

---@param conn Connection
---@param id string|number
---@return GsmModem
function GsmModem.new(conn, id)
	local self = setmetatable({}, GsmModem)
	self.conn = conn
	self.id = id
	self.name = tostring(id)
	self.cfg = {}
	self.device = ""
	self.scope = nil
	self.config_pulse = pulse.new()
	return self
end

---@return nil
function GsmModem:_signal_config_change()
	self.config_pulse:signal()
end

---@param cfg table
---@param name string?
---@return nil
function GsmModem:apply_config(cfg, name)
	self.cfg = cfg or {}
	if name and name ~= "" then
		self.name = name
	end
	self:_signal_config_change()
end

---@param key string
---@param value any
---@return nil
function GsmModem:_emit_metric(key, value)
	if value == nil then
		return
	end
	self.conn:publish(t_obs_metric(self.id, key), value)
end

---@param key string
---@param value any
---@return nil
function GsmModem:_emit_event(key, value)
	if value == nil then
		return
	end
	self.conn:publish(t_obs_event(self.id, key), value)
end

---@return nil
function GsmModem:_emit_metrics_once()
	-- Derived metrics only; HAL remains the source of truth.
	local access_techs, access_err = modem_get_field(self.conn, self.id, 'access_techs', REQUEST_TIMEOUT)
	if access_err ~= "" then
		log.debug("GSM", self.id, "- access_techs:", access_err)
	else
		self:_emit_metric('access_techs', access_techs)
		local access_tech = derive_access_tech(access_techs)
		if access_tech ~= "" then
			self:_emit_metric('access_tech', access_tech)
			local access_family = get_access_family(access_tech)
			if access_family ~= "" then
				self:_emit_metric('access_family', access_family)
			end
		end
	end

	local band, band_err = modem_get_field(self.conn, self.id, 'band', REQUEST_TIMEOUT)
	if band_err ~= "" then
		log.debug("GSM", self.id, "- band:", band_err)
	else
		self:_emit_metric('band', band)
	end

	local imei, imei_err = modem_get_field(self.conn, self.id, 'imei', REQUEST_TIMEOUT)
	if imei_err ~= "" then
		log.debug("GSM", self.id, "- imei:", imei_err)
	else
		self:_emit_metric('imei', imei)
	end

	local operator, operator_err = modem_get_field(self.conn, self.id, 'operator', REQUEST_TIMEOUT)
	if operator_err ~= "" then
		log.debug("GSM", self.id, "- operator:", operator_err)
	else
		self:_emit_metric('operator', operator)
	end

	local sim, sim_err = modem_get_field(self.conn, self.id, 'sim', REQUEST_TIMEOUT)
	if sim_err ~= "" then
		log.debug("GSM", self.id, "- sim:", sim_err)
	else
		self:_emit_metric('sim', normalize_sim_presence(sim))
	end

	local iccid, iccid_err = modem_get_field(self.conn, self.id, 'iccid', REQUEST_TIMEOUT)
	if iccid_err ~= "" then
		log.debug("GSM", self.id, "- iccid:", iccid_err)
	else
		self:_emit_metric('iccid', iccid)
	end

	local firmware, firmware_err = modem_get_field(self.conn, self.id, 'firmware', REQUEST_TIMEOUT)
	if firmware_err ~= "" then
		log.debug("GSM", self.id, "- firmware:", firmware_err)
	else
		self:_emit_metric('firmware', firmware)
	end

	local state, state_err = modem_get_field(self.conn, self.id, 'state', REQUEST_TIMEOUT)
	if state_err ~= "" then
		log.debug("GSM", self.id, "- state:", state_err)
	else
		self:_emit_metric('state', state)
	end

	local net_ports, net_ports_err = modem_get_field(self.conn, self.id, 'net_ports', REQUEST_TIMEOUT)
	if net_ports_err ~= "" then
		log.debug("GSM", self.id, "- net_ports:", net_ports_err)
	else
		local interface = net_ports and net_ports[1]
		if interface then
			self:_emit_metric('interface', interface)
		else
			log.debug("GSM", self.id, "- no net_ports available")
		end
	end

	local rx_bytes, rx_err = modem_get_field(self.conn, self.id, 'rx_bytes', REQUEST_TIMEOUT)
	if rx_err ~= "" then
		log.debug("GSM", self.id, "- rx_bytes:", rx_err)
	else
		self:_emit_metric('rx_bytes', rx_bytes)
	end

	local tx_bytes, tx_err = modem_get_field(self.conn, self.id, 'tx_bytes', REQUEST_TIMEOUT)
	if tx_err ~= "" then
		log.debug("GSM", self.id, "- tx_bytes:", tx_err)
	else
		self:_emit_metric('tx_bytes', tx_bytes)
	end

	local rssi, rssi_err = modem_get_field(self.conn, self.id, 'rssi', REQUEST_TIMEOUT)
	if rssi_err ~= "" then
		log.debug("GSM", self.id, "- rssi:", rssi_err)
	else
		self:_emit_metric('signal_rssi', rssi)
	end

	local rsrp, rsrp_err = modem_get_field(self.conn, self.id, 'rsrp', REQUEST_TIMEOUT)
	if rsrp_err ~= "" then
		log.debug("GSM", self.id, "- rsrp:", rsrp_err)
	else
		self:_emit_metric('signal_rsrp', rsrp)
	end

	local rsrq, rsrq_err = modem_get_field(self.conn, self.id, 'rsrq', REQUEST_TIMEOUT)
	if rsrq_err ~= "" then
		log.debug("GSM", self.id, "- rsrq:", rsrq_err)
	else
		self:_emit_metric('signal_rsrq', rsrq)
	end

	local rscp, rscp_err = modem_get_field(self.conn, self.id, 'rscp', REQUEST_TIMEOUT)
	if rscp_err ~= "" then
		log.debug("GSM", self.id, "- rscp:", rscp_err)
	else
		self:_emit_metric('signal_rscp', rscp)
	end

	local bars_access_tech, signal_value, signal_type = select_signal_for_bars(
		access_techs,
		access_err,
		rssi,
		rssi_err,
		rsrp,
		rsrp_err,
		rscp,
		rscp_err
	)

	if bars_access_tech ~= "" and signal_type ~= "" then
		local bars, bars_err = get_signal_bars(bars_access_tech, signal_type, signal_value)
		if bars_err == "" then
			self:_emit_metric('bars', bars)
		end
	end
end

---@return nil
function GsmModem:_metrics_loop()
	local seen = self.config_pulse:version()
	local interval = tonumber(self.cfg.metrics_interval) or DEFAULT_METRICS_INTERVAL

	while true do
		local which, ver = perform(op.named_choice({
			tick = sleep.sleep_op(interval),
			config = self.config_pulse:changed_op(seen),
		}))

		if which == 'config' then
			if not ver then
				return
			end
			seen = ver
			interval = tonumber(self.cfg.metrics_interval) or DEFAULT_METRICS_INTERVAL
		else
			self:_emit_metrics_once()
		end
	end
end

---@return boolean
---@return string
function GsmModem:_connect_once()
	-- TODO: Add APN selection logic; currently uses a precomputed connection string.
	if not self.cfg.connection_string then
		return false, "missing connection_string"
	end

	local opts, opts_err = external_types.new.ModemConnectOpts(self.cfg.connection_string)
	if not opts then
		return false, opts_err or "invalid connection string"
	end

	local _, err = call_modem_rpc(self.conn, self.id, 'connect', opts, REQUEST_TIMEOUT)
	if err ~= "" then
		return false, err
	end

	return true, ""
end

-- Autoconnect loop: reconnects on a simple backoff and reacts to config changes.
---@return nil
function GsmModem:_autoconnect_loop()
	local seen = self.config_pulse:version()

	while true do
		if not self.cfg.autoconnect then
			local which, ver = perform(op.named_choice({
				idle = sleep.sleep_op(DEFAULT_RETRY_TIMEOUT),
				config = self.config_pulse:changed_op(seen),
			}))

			if which == 'config' then
				if not ver then
					return
				end
				seen = ver
			end
		else
			local ok, err = self:_connect_once()
			if ok then
				self:_emit_event('autoconnect', 'connected')
			else
				self:_emit_event('autoconnect', 'failed')
				log.debug("GSM", self.id, "- autoconnect failed:", err)
			end

			local retry = tonumber(self.cfg.retry_interval) or DEFAULT_RETRY_TIMEOUT
			local which, ver = perform(op.named_choice({
				backoff = sleep.sleep_op(retry),
				config = self.config_pulse:changed_op(seen),
			}))

			if which == 'config' then
				if not ver then
					return
				end
				seen = ver
			end
		end
	end
end

---@param parent_scope Scope
---@return boolean
---@return string
function GsmModem:start(parent_scope)
	if self.scope then
		return true, ""
	end

	if self.config_pulse:is_closed() then
		self.config_pulse = pulse.new()
	end

	local child, err = parent_scope:child()
	if not child then
		return false, err or "failed to create modem scope"
	end

	self.scope = child

	child:finally(function ()
		log.trace("GSM", self.id, "- modem scope closed")
	end)

	local ok, spawn_err = child:spawn(function ()
		local signal_freq = tonumber(self.cfg.signal_freq) or DEFAULT_SIGNAL_FREQ
		local _, sig_err = modem_set_signal_freq(self.conn, self.id, signal_freq)
		if sig_err ~= "" then
			log.debug("GSM", self.id, "- set_signal_update_freq:", sig_err)
		end
	end)
	if not ok then
		return false, spawn_err or "failed to spawn signal update"
	end

	ok, spawn_err = child:spawn(function ()
		self:_metrics_loop()
	end)
	if not ok then
		return false, spawn_err or "failed to spawn metrics loop"
	end

	ok, spawn_err = child:spawn(function ()
		self:_autoconnect_loop()
	end)
	if not ok then
		return false, spawn_err or "failed to spawn autoconnect loop"
	end

	return true, ""
end

---@param reason string?
---@param close_pulse boolean?
---@return nil
function GsmModem:stop(reason, close_pulse)
	if not self.scope then
		return
	end

	self.scope:cancel(reason or 'modem stopped')
	perform(self.scope:join_op())
	self.scope = nil

	if close_pulse then
		self.config_pulse:close(reason or 'modem stopped')
	end
end

---@class GsmService
---@field name string
local GsmService = {}

---@param conn Connection
---@param opts table?
---@return nil
function GsmService.start(conn, opts)
	opts = opts or {}
	local name = opts.name or 'gsm'

	publish_status(conn, name, 'starting')

	local current_cfg = {}
	local config_ready = false
	local modems = {}

	local parent_scope = fibers.current_scope()

	parent_scope:finally(function (_, st, primary)
		for _, modem in pairs(modems) do
			modem:stop(primary or st, true)
		end
		publish_status(conn, name, 'stopped', { reason = primary or st })
	end)

	local function ensure_modem(id)
		local modem = modems[id]
		if modem then
			return modem
		end

		modem = GsmModem.new(conn, id)
		modems[id] = modem

		local device, device_err = modem_get_field(conn, id, 'device', REQUEST_TIMEOUT)
		if device_err ~= "" then
			log.debug("GSM", id, "- device lookup:", device_err)
		else
			modem.device = tostring(device or "")
		end

		local cfg, modem_name, _ = get_modem_config(current_cfg, id, modem.device)
		modem:apply_config(cfg, modem_name)

		local ok, err = modem:start(parent_scope)
		if not ok then
			log.debug("GSM", id, "- failed to start modem scope:", err)
		end

		return modem
	end

	local function remove_modem(id)
		local modem = modems[id]
		if not modem then
			return
		end
		modem:stop('modem removed', true)
		modems[id] = nil
	end

	local cfg_sub = conn:subscribe(t_cfg(name), {
		queue_len = 1,
		full = 'drop_oldest',
	})

	while not config_ready do
		local which, msg, err = perform(op.named_choice({
			cfg = cfg_sub:recv_op(),
			timeout = sleep.sleep_op(REQUEST_TIMEOUT),
		}))

		if which == 'timeout' then
			log.warn("GSM", "- waiting for initial config")
		else
			if not msg then
				log.warn("GSM", "- config subscription closed:", err)
				return
			end
			if not is_plain_table(msg.payload) then
				log.warn("GSM", "- invalid config payload")
			else
				local cfg, cfg_err = normalize_config(msg.payload)
				if cfg_err ~= "" then
					log.warn("GSM", "- invalid config:", cfg_err)
				else
					current_cfg = cfg
					config_ready = true
				end
			end
		end
	end

	local cap_sub = conn:subscribe(t_cap_state('+'), {
		queue_len = 1,
		full = 'drop_oldest',
	})

	publish_status(conn, name, 'running')

	while true do
		local which, msg, err = perform(op.named_choice({
			cap = cap_sub:recv_op(),
			cfg = cfg_sub:recv_op(),
		}))

		if not msg then
			log.debug("GSM", "- subscription closed:", err)
			return
		end

		if which == 'cap' then
			local id = msg.topic and msg.topic[3]
			if msg.payload == 'added' then
				ensure_modem(id)
			elseif msg.payload == 'removed' then
				remove_modem(id)
			else
				log.debug("GSM", id, "- unknown modem state:", msg.payload)
			end
		else
			if not is_plain_table(msg.payload) then
				log.debug("GSM", "- invalid config payload")
			else
				local updated_cfg, cfg_err = normalize_config(msg.payload)
				if cfg_err ~= "" then
					log.debug("GSM", "- invalid config:", cfg_err)
				else
					current_cfg = updated_cfg
					for id, modem in pairs(modems) do
						local modem_cfg, modem_name, _ = get_modem_config(current_cfg, id, modem.device)
						modem:apply_config(modem_cfg, modem_name)
						modem:stop('config change')
						modem:start(parent_scope)
					end
				end
			end
		end
	end
end

return GsmService
