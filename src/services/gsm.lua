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
local apns = require "services.gsm.apn"

local REQUEST_TIMEOUT = 10
local DEFAULT_RETRY_TIMEOUT = 20
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
	{ tokens = { '5gnr' },        tech = '5g' },
	{ tokens = { '5g' },          tech = '5g' },
	{ tokens = { 'lte' },         tech = 'lte' },
	{ tokens = { 'umts' },        tech = 'umts' },
	{ tokens = { 'gsm' },         tech = 'gsm' },
	{ tokens = { 'evdo' },        tech = 'evdo' },
	{ tokens = { 'cdma1x' },      tech = 'cdma1x' },
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
---@return table
local function t_cap_card_state(id)
	return { 'cap', 'modem', id, 'state', 'card' }
end

---@param id string|number
---@param method string
---@return table
local function t_cap_rpc(id, method)
	return { 'cap', 'modem', id, 'rpc', method }
end

---@param key string
---@return table
local function t_obs_metric(key)
	return { 'obs', 'v1', 'gsm', 'metric', key }
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
		return nil, err or "rpc failed"
	end
	if reply.ok ~= true then
		return nil, reply.reason or 'rpc failed'
	end
	return reply.reason, ""
end

---@param conn Connection
---@param id string|number
---@param field string
---@param timeout number?
---@param timescale number?
---@return any
---@return string
local function modem_get_field(conn, id, field, timeout, timescale)
	local opts, opts_err = external_types.new.ModemGetOpts(field, timescale)
	if not opts then
		return nil, opts_err or "invalid modem get opts"
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
---@param rssi any
---@param rsrp any
---@param rscp any
---@return string
---@return number
---@return string
local function select_signal_for_bars(access_techs, rssi, rsrp, rscp)
	if not access_techs then
		return "", 0, "access tech unavailable"
	end

	local access_tech = derive_access_tech(access_techs)
	if access_tech == "" then
		return "", 0, "access tech unknown"
	end

	if access_tech == 'umts' and rscp ~= nil then
		local rscp_value = tonumber(rscp)
		if rscp_value then
			return access_tech, rscp_value, "rscp"
		end
	end

	if (access_tech == 'lte' or access_tech == '5g') and rsrp ~= nil then
		local rsrp_value = tonumber(rsrp)
		if rsrp_value then
			return access_tech, rsrp_value, "rsrp"
		end
	end

	if rssi ~= nil then
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
					or (id_field ~= 'device' and (entry.imei == imei))
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

--- Waits for a modem state to move out of connecting
---@param name string
---@param state_sub Subscription
---@return boolean ok
---@return string error
local function wait_for_connection(name, state_sub)
	while true do
		local msg, err = state_sub:recv()
		if err then
			return false, "state subscription interrupted"
		end
		local state = msg.payload and msg.payload.to
		log.trace(("GSM %s connection progress - modem state change: %s"):format(tostring(name), tostring(state)))
		if state and state ~= 'connecting' then
			return true, ""
		end
	end
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
	log.info("GSM", self.name, "- emitting metric", key, "=", tostring(value))
	if value == nil then
		return
	end
	local ns_name = nil
	if self.name == "primary" then
		ns_name = "1"
	elseif self.name == "secondary" then
		ns_name = "2"
	else
		return
	end
	local metric = {
		value = value,
		namespace = {'modem', ns_name, key}
	}
	self.conn:publish(t_obs_metric(key), metric)
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
	if access_err == "" then
		local access_tech = derive_access_tech(access_techs)
		if access_tech ~= "" then
			self:_emit_metric('access_tech', access_tech)
			local access_family = get_access_family(access_tech)
			if access_family ~= "" then
				self:_emit_metric('access_family', access_family)
			end
		end
	end

	local band, band_err = modem_get_field(self.conn, self.id, 'active_band_class', REQUEST_TIMEOUT)
	if band_err == "" then
		self:_emit_metric('band', band)
	end

	local imei, imei_err = modem_get_field(self.conn, self.id, 'imei', REQUEST_TIMEOUT)
	if imei_err == "" then
		self:_emit_metric('imei', imei)
	end

	local operator, operator_err = modem_get_field(self.conn, self.id, 'operator', REQUEST_TIMEOUT)
	if operator_err == "" then
		self:_emit_metric('operator', operator)
	end

	local sim, sim_err = modem_get_field(self.conn, self.id, 'sim', REQUEST_TIMEOUT)
	if sim_err == "" then
		self:_emit_metric('sim', normalize_sim_presence(sim))
	end

	local iccid, iccid_err = modem_get_field(self.conn, self.id, 'iccid', REQUEST_TIMEOUT)
	if iccid_err == "" then
		self:_emit_metric('iccid', iccid)
	end

	local firmware, firmware_err = modem_get_field(self.conn, self.id, 'firmware', REQUEST_TIMEOUT)
	if firmware_err == "" then
		self:_emit_metric('firmware', firmware)
	end

	local state_sub = self.conn:subscribe(t_cap_card_state(self.id))
	local state_msg, msg_err = state_sub:recv()
	if msg_err then
		log.debug("GSM", self.name, "- state: ", msg_err)
	end
	local state = state_msg.payload and state_msg.payload.to
	---@cast state ModemStateEvent
	if state then
		self:_emit_metric('state', state.to)
	end

	local net_ports, net_ports_err = modem_get_field(self.conn, self.id, 'net_ports', REQUEST_TIMEOUT)
	if net_ports_err == "" then
		local interface = net_ports and net_ports[1]
		if interface then
			self:_emit_metric('interface', interface)
		else
			log.debug("GSM", self.name, "- no net_ports available")
		end
	end

	local rx_bytes, rx_err = modem_get_field(self.conn, self.id, 'rx_bytes', REQUEST_TIMEOUT)
	if rx_err == "" then
		self:_emit_metric('rx_bytes', rx_bytes)
	end

	local tx_bytes, tx_err = modem_get_field(self.conn, self.id, 'tx_bytes', REQUEST_TIMEOUT)
	if tx_err == "" then
		self:_emit_metric('tx_bytes', tx_bytes)
	end

	local signal, signal_err = modem_get_field(self.conn, self.id, 'signal', REQUEST_TIMEOUT)
	local rssi, rsrp, rsrq, rscp = nil, nil, nil, nil
	if signal_err == "" then
		rssi = signal.rssi
		rsrp = signal.rsrp
		rsrq = signal.rsrq
		rscp = signal.rscp
	end

	if rsrp then
		self:_emit_metric('rsrp', rsrp)
	end

	if rsrq then
		self:_emit_metric('rsrq', rsrq)
	end

	local bars_access_tech, signal_value, signal_type = select_signal_for_bars(
		access_techs,
		rssi,
		rsrp,
		rscp
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

---@return table|nil apn
---@return string error
---@return number? retry_timeout
function GsmModem:_apn_connect()
	-- Fetch network/SIM identifiers from HAL
	local mcc, mcc_err = modem_get_field(self.conn, self.id, 'mcc', REQUEST_TIMEOUT)
	if mcc_err ~= "" then
		return nil, "mcc: " .. mcc_err, DEFAULT_RETRY_TIMEOUT
	end

	local mnc, mnc_err = modem_get_field(self.conn, self.id, 'mnc', REQUEST_TIMEOUT)
	if mnc_err ~= "" then
		return nil, "mnc: " .. mnc_err, DEFAULT_RETRY_TIMEOUT
	end

	local imsi, imsi_err = modem_get_field(self.conn, self.id, 'imsi', REQUEST_TIMEOUT)
	if imsi_err ~= "" then
		return nil, "imsi: " .. imsi_err, DEFAULT_RETRY_TIMEOUT
	end

	local gid1, gid1_err = modem_get_field(self.conn, self.id, 'gid1', REQUEST_TIMEOUT)
	if gid1_err ~= "" then
		return nil, "gid1: " .. gid1_err, DEFAULT_RETRY_TIMEOUT
	end

	-- Get ranked APNs
	local rank_cutoff = tonumber(self.cfg.apn_rank_cutoff) or 4
	local ranked_apns, rankings = apns.get_ranked_apns(mcc, mnc, imsi, nil, gid1)

	-- Iterate through ranked APNs
	for _, ranking in ipairs(rankings) do
		if ranking.rank > rank_cutoff then break end

		local apn_table = ranked_apns[ranking.name]
		local conn_str, build_err = apns.build_connection_string(apn_table, self.cfg.roaming_allow)

		if not build_err and conn_str then
			-- Build and send connect RPC
			local opts, opts_err = external_types.new.ModemConnectOpts(conn_str)
			if opts then
				log.trace("GSM", self.name, "- attempting to connect APN", ranking.name, "with connection string:",
					conn_str)

				local _, conn_err = call_modem_rpc(self.conn, self.id, 'connect', opts, REQUEST_TIMEOUT)

				log.debug("GSM", self.name, "- connect RPC for APN", ranking.name, "returned:", conn_err)
				if conn_err == "" then
					-- Connect succeeded
					log.trace("GSM", self.name, "- APN", ranking.name, "connected successfully")
					return apn_table, "", nil
				end

				-- Check for throttled error
				if string.find(conn_err, "pdn-ipv4-call-throttled") then
					log.debug("GSM", self.name, "- APN connection throttled")
					return nil, conn_err, 360 -- 6-minute backoff
				end

				-- Connection attempt failed, wait for modem state to stabilize before trying next APN
				log.debug("GSM", self.name, "- APN", ranking.name, "connect failed:", conn_err,
					"waiting for state change")

				-- Subscribe to state changes to monitor connection progress
				local state_sub = self.conn:subscribe(t_cap_card_state(self.id), {
					queue_len = 1,
					full = 'drop_oldest',
				})
				local ok, wait_err = wait_for_connection(self.name, state_sub)
				state_sub:unsubscribe()
				if not ok then
					log.debug("GSM", self.name, "- error while waiting for state change, failure:", wait_err)
					return nil, wait_err, DEFAULT_RETRY_TIMEOUT
				end

				log.trace("GSM", self.name, "- APN", ranking.name, "connection attempt failed")
			else
				log.debug("GSM", self.name, "- invalid connect opts for APN", ranking.name, ":", opts_err)
			end
		else
			log.debug("GSM", self.name, "- failed to build connection string for APN", ranking.name, ":",
				build_err or "nil")
		end
	end

	state_sub:unsubscribe()
	return nil, "no apn connected", DEFAULT_RETRY_TIMEOUT
end

-- Autoconnect loop: listens to modem state changes and reacts with enable/fix/connect.
-- Retry logic with exponential backoff and state change preemption.
---@return nil
function GsmModem:_autoconnect_loop()
	local seen = self.config_pulse:version()
	local state_sub = self.conn:subscribe(t_cap_card_state(self.id), {
		queue_len = 1,
		full = 'drop_oldest',
	})

	local current_state = nil
	local backoff = math.huge

	while true do
		local which, msg_or_ver = perform(op.named_choice({
			state = state_sub:recv_op(),
			backoff = sleep.sleep_op(backoff),
			config = self.config_pulse:changed_op(seen),
		}))

		if which == 'config' then
			if not msg_or_ver then
				-- pulse closed, exit
				break
			end
			seen = msg_or_ver
			backoff = math.huge
		elseif which == 'state' then
			local msg = msg_or_ver
			if msg then
				current_state = msg.payload.to
				log.trace("GSM", self.name, "- modem state changed:", current_state)
			end
		elseif which == 'backoff' then
			log.trace("GSM", self.name, "- retrying state:", current_state)
		end

		-- Act on current_state
		if current_state and self.cfg.autoconnect then
			local err, retry_timeout

			if current_state == 'disabled' then
				local _, err_inner = call_modem_rpc(self.conn, self.id, 'enable', {}, REQUEST_TIMEOUT)
				err = err_inner
			elseif current_state == 'failed' then
				local _, err_inner = call_modem_rpc(self.conn, self.id, 'listen_for_sim', {}, REQUEST_TIMEOUT)
				err = err_inner
			elseif current_state == 'registered' then
				local _, err_inner, retry_inner = self:_apn_connect()
				err = err_inner
				retry_timeout = retry_inner
				if err == "" then
					self:_emit_event('autoconnect', 'connected')
				end
			end

			if err and err ~= "" then
				backoff = retry_timeout or DEFAULT_RETRY_TIMEOUT
				log.error("GSM", self.name, "- state", current_state, "failed:", err,
					"retrying after", backoff, "seconds")
			else
				backoff = math.huge
			end
		end
	end

	state_sub:unsubscribe()
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

	child:finally(function()
		log.trace("GSM", self.name, "- modem scope closed")
	end)

	local ok, spawn_err = child:spawn(function()
		local signal_freq = tonumber(self.cfg.signal_freq) or DEFAULT_SIGNAL_FREQ
		local _, sig_err = modem_set_signal_freq(self.conn, self.id, signal_freq)
		if sig_err ~= "" then
			log.debug("GSM", self.name, "- set_signal_update_freq:", sig_err)
		end
	end)
	if not ok then
		return false, spawn_err or "failed to spawn signal update"
	end

	ok, spawn_err = child:spawn(function()
		self:_metrics_loop()
	end)
	if not ok then
		return false, spawn_err or "failed to spawn metrics loop"
	end

	ok, spawn_err = child:spawn(function()
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

	if close_pulse then
		self.config_pulse:close(reason or 'modem stopped')
	end

	self.scope:cancel(reason or 'modem stopped')
	perform(self.scope:join_op())
	self.scope = nil
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

	---@type table<string, GsmModem>
	local modems = {}

	local parent_scope = fibers.current_scope()

	parent_scope:finally(function(_, st, primary)
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
			log.error("GSM", id, "- failed to start modem scope:", err)
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

	local cfg_sub = conn:subscribe(t_cfg(name))

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

	local cap_sub = conn:subscribe(t_cap_state('+'))

	publish_status(conn, name, 'running')

	while true do
		local choices = {
			cap = cap_sub:recv_op(),
			cfg = cfg_sub:recv_op(),
		}

		local modem_fault_ops = {}
		for id, modem in pairs(modems) do
			table.insert(modem_fault_ops, modem.scope:fault_op():wrap(function(_, pr)
				return { id = id, primary = pr }
			end))
		end

		if #modem_fault_ops > 0 then
			choices.modem_fault = op.choice(unpack(modem_fault_ops))
		end

		local which, msg, err = perform(op.named_choice(choices))

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
		elseif which == 'modem_fault' then
			local modem = modems[msg.id]
			if modem then
				log.debug("GSM", msg.id, "- modem scope faulted: " .. tostring(msg.primary))
				modem:stop()
			end
		elseif which == 'cfg' then
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
