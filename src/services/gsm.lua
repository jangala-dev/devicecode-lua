-- services/gsm.lua
--
-- GSM service (new fibers):
--  - consumes HAL modem capabilities
--  - runs per-modem child scopes for autoconnect + metrics
--  - publishes derived observability metrics and canonical modem state
--
-- Topics consumed:
--   cfg/<name>                              service config (retained)
--   cap/modem/+/state                       HAL modem capability add/remove events
--
-- Topics produced:
--   svc/<name>/announce                     service lifecycle announce
--   svc/<name>/status                       service lifecycle status
--   obs/v1/gsm/metric/<key>                 per-modem observability metrics
--   obs/v1/gsm/event/<key>                  per-modem observability events
--   state/gsm/modem/<name>/connected        retained: true when APN connected, false otherwise
--   state/gsm/modem/<name>/wwan-iface       retained: kernel wwan interface name, false when unknown
--   state/gsm/uplink/<name>                 retained: canonical cellular uplink record for NET

local fibers = require "fibers"
local op = require "fibers.op"
local sleep = require "fibers.sleep"
local pulse = require "fibers.pulse"

local perform = fibers.perform

local base = require 'devicecode.service_base'
local cap_sdk = require 'services.hal.sdk.cap'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local apns = require "services.gsm.apn"
local gsm_topics = require 'services.gsm.topics'
local apn_model = require 'services.gsm.apn_model'
local apn_store_control = require 'services.gsm.apn_store_control_store'
local tablex = require 'shared.table'

local copy = tablex.deep_copy

local REQUEST_TIMEOUT = 10
local DEFAULT_RETRY_TIMEOUT = 20
local DEFAULT_METRICS_INTERVAL = 120
local DEFAULT_SIGNAL_FREQ = 5
local APN_SETTLE_TIMEOUT = 3 -- seconds to wait for modem to enter 'connecting' after a failed attempt

local SCHEMA_STANDARD = "devicecode.config/gsm/1"

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

local STATE_CONNECTED = 'connected'

-- Topic helpers (centralized so we can remap if needed)
---@param name string
---@return table
local function t_cfg(name)
	return { 'cfg', name }
end

---@param name string
---@param field string
---@return table
local function t_state_gsm_modem(name, field)
	return { 'state', 'gsm', 'modem', name, field }
end

local function t_state_gsm_uplink(name)
	return { 'state', 'gsm', 'uplink', name }
end


---@param cap CapabilityReference
---@param method string
---@param payload table?
---@param timeout number?
---@return any
---@return string
local function call_modem_rpc(cap, method, payload, timeout)
	local reply, err = perform(cap:call_control_op(method, payload or {}, {
		timeout = timeout or REQUEST_TIMEOUT,
	}))
	if not reply then
		return nil, err or "rpc failed"
	end
	if reply.ok ~= true then
		return nil, reply.reason or 'rpc failed'
	end
	return reply.reason, ""
end

---@param cap CapabilityReference
---@param field string
---@param timeout number?
---@param timescale number?
---@return any
---@return string
local function modem_get_field(cap, field, timeout, timescale)
	local opts, opts_err = cap_sdk.args.new.ModemGetOpts(field, timescale)
	if not opts then
		return nil, opts_err or "invalid modem get opts"
	end
	return call_modem_rpc(cap, 'get', opts, timeout)
end

---@param cap CapabilityReference
---@param freq number
---@return any
---@return string
local function modem_set_signal_freq(cap, freq)
	local opts, opts_err = cap_sdk.args.new.ModemSignalUpdateOpts(freq)
	if not opts then
		return false, opts_err or "invalid signal update opts"
	end
	return call_modem_rpc(cap, 'set_signal_update_freq', opts, REQUEST_TIMEOUT)
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
	if cfg.schema ~= SCHEMA_STANDARD then
		return {}, "config schema must be " .. SCHEMA_STANDARD
	end
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
	local apn_store = rawget(cfg, 'apn_store')
	if apn_store ~= nil and not is_plain_table(apn_store) then
		return {}, "config.apn_store must be a table"
	end
	local out = shallow_copy(cfg)
	out.schema = nil
	return out, ""
end

---@param cfg table
---@param imei string|number
---@param device string
---@return table
---@return string
---@return string
local function get_modem_config(cfg, imei, device)
	local modem_base = shallow_copy(cfg.modems and cfg.modems.default or {})
	local known = cfg.modems and cfg.modems.known
	if type(known) == 'table' then
		for _, entry in ipairs(known) do
			if is_plain_table(entry) then
				local id_field = entry.id_field or 'imei'
				if (id_field == 'device' and device ~= "" and entry.device == device)
					or (id_field ~= 'device' and (entry.imei == imei))
				then
					local merged = shallow_copy(entry)
					apply_defaults(merged, modem_base)
					return merged, (merged.name or ""), ""
				end
			end
		end
	end

	return modem_base, "", ""
end

--- Waits for a modem connection attempt to settle.
--- Phase 1: waits for the modem to enter 'connecting'. If the modem never enters
--- 'connecting' within APN_SETTLE_TIMEOUT seconds (ModemManager rejected the command
--- immediately), we consider it settled and return. Phase 2: once connecting, waits
--- (without a timeout) until the modem leaves 'connecting'.
--- Expects that the caller has already drained the retained current-state message from
--- the subscription so only live transitions are seen here.
---@param name string
---@param state_sub Subscription
---@param log_fn function?
---@return boolean ok
---@return string error
local function wait_for_connection(name, state_sub, log_fn)
	log_fn = log_fn or function(_, _) end

	-- Phase 1: wait for 'connecting', or give up after APN_SETTLE_TIMEOUT seconds.
	while true do
		local which, msg = perform(op.named_choice({
			state  = state_sub:recv_op(),
			settle = sleep.sleep_op(APN_SETTLE_TIMEOUT),
		}))

		if which == 'settle' then
			-- Modem never entered 'connecting'; ModemManager likely rejected the command
			-- immediately (e.g. modem busy, wrong state). Treat as settled.
			log_fn('debug', { what = 'connection_settled', modem = name })
			return true, ""
		end

		if not msg then
			return false, "state subscription interrupted"
		end

		local state = msg.payload and msg.payload.to
		log_fn('debug', { what = 'connection_progress', modem = name, modem_state = tostring(state) })

		if state == 'connecting' then
			break
		end
		-- Any other state (e.g. a transient non-connecting event): keep waiting.
	end

	-- Phase 2: modem entered 'connecting'; wait until it leaves.
	while true do
		local msg, err = state_sub:recv()
		if err then
			return false, "state subscription interrupted"
		end
		local state = msg.payload and msg.payload.to
		log_fn('debug', { what = 'connection_progress', modem = name, modem_state = tostring(state) })
		if state and state ~= 'connecting' then
			return true, ""
		end
	end
end

---@class GsmModem
---@field conn Connection
---@field cap CapabilityReference
---@field id string|number
---@field name string
---@field cfg table
---@field device string
---@field scope Scope?
---@field config_pulse Pulse
---@field svc ServiceBase

local function id_suffix(id)
	id = tostring(id or '')
	if #id <= 4 then return id end
	return '…' .. id:sub(-4)
end

local function modem_label(self)
	local role = tostring(self.name or self.id or 'modem')
	local suffix = id_suffix(self.id)
	if suffix ~= '' and suffix ~= role then return role .. ' ' .. suffix end
	return role
end

local function normalised_sim_string(v)
	if v == nil then return nil end
	local n = normalize_sim_presence(v)
	if n == nil then return tostring(v) end
	return tostring(n)
end

local function log_modem_detected(modem, fields)
	if not modem or not modem.svc then return end
	fields = fields or {}
	local key = table.concat({
		tostring(modem.name or ''),
		tostring(modem.id or ''),
		tostring(modem.device or ''),
		tostring(fields.firmware or ''),
		tostring(fields.sim or ''),
		tostring(fields.ifname or modem.wwan_iface or ''),
	}, '|')
	if modem._last_inventory_key == key then return end
	modem._last_inventory_key = key
	local parts = { tostring(modem.name or 'modem'), id_suffix(modem.id), 'detected' }
	if fields.firmware then parts[#parts + 1] = 'fw=' .. tostring(fields.firmware) end
	if fields.sim ~= nil then parts[#parts + 1] = 'sim=' .. tostring(fields.sim) end
	if fields.ifname or modem.wwan_iface then parts[#parts + 1] = 'ifname=' .. tostring(fields.ifname or modem.wwan_iface) end
	if modem.device and modem.device ~= '' then parts[#parts + 1] = 'device=' .. tostring(modem.device):match('[^/]+$') end
	modem.svc:info('modem_detected', {
		summary = table.concat(parts, ' '),
		modem = modem.name,
		modem_id = tostring(modem.id),
		device = modem.device,
		firmware = fields.firmware,
		sim = fields.sim,
		ifname = fields.ifname or modem.wwan_iface,
	})
end


local function modem_summary_state(modem)
	if not modem then return 'missing' end
	if modem.current_state then return tostring(modem.current_state) end
	if modem.connected then return 'connected' end
	return 'detected'
end

local function expected_role_count(svc)
	local roles = svc and svc._gsm_expected_roles or nil
	if type(roles) ~= 'table' then return 0 end
	local n = 0
	for _ in pairs(roles) do n = n + 1 end
	return n
end

local function derive_expected_roles(cfg)
	local roles = {}
	local known = cfg and cfg.modems and cfg.modems.known
	if type(known) == 'table' then
		for i, entry in ipairs(known) do
			if is_plain_table(entry) then
				roles[tostring(entry.name or ('modem' .. tostring(i)))] = true
			end
		end
	end
	return roles
end

local function log_gsm_summary(svc, modems, reason)
	if not svc then return end
	local parts = {}
	local roles = {}
	for _, modem in pairs(modems or {}) do roles[#roles + 1] = tostring(modem.name or modem.id or 'modem') end
	table.sort(roles)
	local expected_n = expected_role_count(svc)
	if expected_n > 0 and #roles < expected_n then return end
	for _, role in ipairs(roles) do
		for _, modem in pairs(modems or {}) do
			if tostring(modem.name or modem.id or 'modem') == role then
				local piece = role .. '=' .. modem_summary_state(modem)
				if modem.wwan_iface then piece = piece .. '(' .. tostring(modem.wwan_iface) .. ')' end
				parts[#parts + 1] = piece
			end
		end
	end
	if #parts == 0 then parts[#parts + 1] = 'modems=none' end
	local summary = 'gsm summary ' .. table.concat(parts, ' ')
	local tnow = fibers.now()
	if svc._gsm_summary_key == summary and (tnow - (svc._gsm_summary_at or 0)) < 600 then return end
	svc._gsm_summary_key = summary
	svc._gsm_summary_at = tnow
	svc:info('gsm_summary', { summary = summary, reason = reason })
end

local GsmModem = {}
GsmModem.__index = GsmModem

---@param cap CapabilityReference
---@param svc ServiceBase
---@return GsmModem
function GsmModem.new(cap, svc)
	local self = setmetatable({}, GsmModem)
	self.cap = cap
	self.conn = cap.conn
	self.id = cap.id
	self.name = tostring(cap.id)
	self.cfg = {}
	self.device = ""
	self.connected = false
	self.wwan_iface = nil
	self.last_access = nil
	self.last_signal = nil
	self.current_state = nil
	self.uplink_generation = 0
	self.scope = nil
	self.config_pulse = pulse.new()
	self.svc = svc
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
	local ns_name
	if self.name == "primary" then
		ns_name = "1"
	elseif self.name == "secondary" then
		ns_name = "2"
	else
		return
	end
	self.svc:obs_metric(key, {
		value = value,
		namespace = { 'modem', ns_name, key },
	})
end

---@param key string
---@param value any
---@return nil
function GsmModem:_emit_event(key, value)
	if value == nil then
		return
	end
	self.svc:obs_event(key, { modem = self.name, value = value })
end

---@return nil

---@param connected boolean?
---@param iface string?
---@return nil
function GsmModem:_publish_uplink_state(connected, iface)
	if connected ~= nil then self.connected = connected == true end
	if type(iface) == 'string' and iface ~= '' then self.wwan_iface = iface end
	self.uplink_generation = (self.uplink_generation or 0) + 1

	local access_techs = modem_get_field(self.cap, 'access_techs', REQUEST_TIMEOUT)
	local access_tech = derive_access_tech(access_techs)
	local operator = modem_get_field(self.cap, 'operator', REQUEST_TIMEOUT)
	local signal = modem_get_field(self.cap, 'signal', REQUEST_TIMEOUT)
	local ifname = self.wwan_iface
	local payload = {
		schema = 'devicecode.gsm.uplink/1',
		id = self.name,
		role = self.name,
		state = self.connected and 'connected' or 'disconnected',
		connected = self.connected == true,
		available = self.connected == true and type(ifname) == 'string' and ifname ~= '',
		generation = self.uplink_generation,
		linux = { ifname = ifname },
		modem = {
			id = tostring(self.id),
			role = self.name,
			device = self.device,
		},
		access = {
			tech = access_tech ~= '' and access_tech or nil,
			family = access_tech ~= '' and get_access_family(access_tech) or nil,
			operator = operator,
		},
		signal = type(signal) == 'table' and signal or nil,
		at = self.svc and self.svc.wall and self.svc:wall() or nil,
	}
	self.conn:retain(t_state_gsm_uplink(self.name), payload)
end

function GsmModem:_emit_metrics_once()
	-- Derived metrics only; HAL remains the source of truth.
	local inventory = {}
	local access_techs, access_err = modem_get_field(self.cap, 'access_techs', REQUEST_TIMEOUT)
	if access_err == "" then
		local access_tech = derive_access_tech(access_techs)
		if access_tech ~= "" then
			inventory.access_tech = access_tech
			self:_emit_metric('access_tech', access_tech)
			local access_family = get_access_family(access_tech)
			if access_family ~= "" then
				self:_emit_metric('access_fam', access_family)
			end
		end
	end

	local band, band_err = modem_get_field(self.cap, 'active_band_class', REQUEST_TIMEOUT)
	if band_err == "" then
		self:_emit_metric('band', band)
	end

	local imei, imei_err = modem_get_field(self.cap, 'imei', REQUEST_TIMEOUT)
	if imei_err == "" then
		inventory.imei = imei
		self:_emit_metric('imei', imei)
	end

	local operator, operator_err = modem_get_field(self.cap, 'operator', REQUEST_TIMEOUT)
	if operator_err == "" then
		inventory.operator = operator
		self:_emit_metric('operator', operator)
	end

	local sim, sim_err = modem_get_field(self.cap, 'sim', REQUEST_TIMEOUT)
	if sim_err == "" then
		inventory.sim = normalised_sim_string(sim)
		self:_emit_metric('sim', normalize_sim_presence(sim))
	end

	local iccid, iccid_err = modem_get_field(self.cap, 'iccid', REQUEST_TIMEOUT)
	if iccid_err == "" then
		self:_emit_metric('iccid', iccid)
	end

	local firmware, firmware_err = modem_get_field(self.cap, 'firmware', REQUEST_TIMEOUT)
	if firmware_err == "" then
		inventory.firmware = firmware
		self:_emit_metric('fw_version', firmware)
	end

	local state_sub = self.cap:get_state_sub('card')
	local state_msg, msg_err = state_sub:recv()
	state_sub:unsubscribe()
	if msg_err then
		self.svc:obs_log('debug', { what = 'state_recv_error', modem = self.name, err = tostring(msg_err) })
	end

	local state = state_msg.payload and state_msg.payload
	---@cast state ModemStateEvent
	if state then
		self:_emit_metric('state', state.to)
	end

	local net_ports, net_ports_err = modem_get_field(self.cap, 'net_ports', REQUEST_TIMEOUT)
	if net_ports_err == "" then
		local interface = net_ports and net_ports[1]
		if interface then
			self.wwan_iface = interface
			inventory.ifname = interface
			self:_emit_metric('wann_type', interface)
			self.conn:retain(t_state_gsm_modem(self.name, 'wwan-iface'), interface)
			self:_publish_uplink_state(nil, interface)
		else
			self.svc:obs_log('debug', { what = 'no_net_ports', modem = self.name })
		end
	end

	local rx_bytes, rx_err = modem_get_field(self.cap, 'rx_bytes', REQUEST_TIMEOUT)
	if rx_err == "" then
		self:_emit_metric('rx_bytes', rx_bytes)
	end

	local tx_bytes, tx_err = modem_get_field(self.cap, 'tx_bytes', REQUEST_TIMEOUT)
	if tx_err == "" then
		self:_emit_metric('tx_bytes', tx_bytes)
	end

	local signal, signal_err = modem_get_field(self.cap, 'signal', REQUEST_TIMEOUT)
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

	if rssi then
		self:_emit_metric('rssi', rssi)
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
	log_modem_detected(self, inventory)
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
	local mcc, mcc_err = modem_get_field(self.cap, 'mcc', REQUEST_TIMEOUT)
	if mcc_err ~= "" then
		return nil, "mcc: " .. mcc_err, DEFAULT_RETRY_TIMEOUT
	end

	local mnc, mnc_err = modem_get_field(self.cap, 'mnc', REQUEST_TIMEOUT)
	if mnc_err ~= "" then
		return nil, "mnc: " .. mnc_err, DEFAULT_RETRY_TIMEOUT
	end

	local imsi, imsi_err = modem_get_field(self.cap, 'imsi', REQUEST_TIMEOUT)
	if imsi_err ~= "" then
		return nil, "imsi: " .. imsi_err, DEFAULT_RETRY_TIMEOUT
	end

	local gid1, gid1_err = modem_get_field(self.cap, 'gid1', REQUEST_TIMEOUT)
	if gid1_err ~= "" then
		return nil, "gid1: " .. gid1_err, DEFAULT_RETRY_TIMEOUT
	end

	-- Get ranked APNs
	local rank_cutoff = tonumber(self.cfg.apn_rank_cutoff) or 4
	local ranked_apns, rankings = apns.get_ranked_apns(mcc, mnc, imsi, nil, gid1, self.svc and self.svc.custom_apns)

	-- Iterate through ranked APNs
	for _, ranking in ipairs(rankings) do
		if ranking.rank > rank_cutoff then break end

		local apn_table = ranked_apns[ranking.name]
		local conn_str, build_err = apns.build_connection_string(apn_table, self.cfg.roaming_allow)

		if not build_err and conn_str then
			-- Build and send connect RPC
			local opts, opts_err = cap_sdk.args.new.ModemConnectOpts(conn_str)
			if opts then
				-- Subscribe before connecting so we capture real state transitions.
				-- Retained messages are delivered synchronously into the mailbox during
				-- subscribe(), so recv() returns immediately with the stale current state.
				-- Draining it here ensures wait_for_connection only sees live transitions.
				local state_sub = self.cap:get_state_sub('card', {
					queue_len = 4,
					full = 'drop_oldest',
				})
				state_sub:recv() -- drain the retained current state

				self.svc:obs_log('debug',
					{ what = 'apn_connect_attempt', modem = self.name, apn = ranking.name, conn_str = conn_str })

				local _, conn_err = call_modem_rpc(self.cap, 'connect', opts, REQUEST_TIMEOUT)

				self.svc:obs_log('debug',
					{ what = 'apn_connect_rpc', modem = self.name, apn = ranking.name, err = conn_err })
				if conn_err == "" then
					-- Connect succeeded
					self.svc:obs_log('info', { what = 'apn_connected', modem = self.name, apn = ranking.name })
					state_sub:unsubscribe()
					return apn_table, "", nil
				end

				-- Check for throttled error
				if string.find(conn_err, "pdn-ipv4-call-throttled") then
					self.svc:obs_log('warn', { what = 'apn_throttled', modem = self.name })
					state_sub:unsubscribe()
					return nil, conn_err, 360 -- 6-minute backoff
				end

				-- Connection attempt failed; wait for modem state to stabilize before trying next APN.
				self.svc:obs_log('debug',
					{ what = 'apn_connect_failed', modem = self.name, apn = ranking.name, err = conn_err })

				local ok, wait_err = wait_for_connection(
					self.name, state_sub,
					function(level, payload) self.svc:obs_log(level, payload) end
				)
				state_sub:unsubscribe()
				if not ok then
					self.svc:obs_log('warn', { what = 'wait_for_connection_failed', modem = self.name, err = wait_err })
					return nil, wait_err, DEFAULT_RETRY_TIMEOUT
				end

				self.svc:obs_log('warn', { what = 'apn_attempt_failed', modem = self.name, apn = ranking.name })
			else
				self.svc:obs_log('debug',
					{ what = 'apn_invalid_opts', modem = self.name, apn = ranking.name, err = opts_err })
			end
		else
			self.svc:obs_log('debug',
				{ what = 'apn_build_failed', modem = self.name, apn = ranking.name, err = build_err or 'nil' })
		end
	end

	return nil, "no apn connected", DEFAULT_RETRY_TIMEOUT
end

-- Autoconnect loop: listens to modem state changes and reacts with enable/fix/connect.
-- Retry logic with exponential backoff and state change preemption.
---@return nil
function GsmModem:_autoconnect_loop()
	self.svc:obs_log('debug', self.name .. ": starting autoconnect loop")
	local seen = self.config_pulse:version()
	local state_sub = self.cap:get_state_sub('card', {
		queue_len = 1,
		full = 'drop_oldest',
	})

	local current_state = nil
	local connected = false
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
				self.current_state = current_state
				if current_state ~= self._last_operator_state then
					self._last_operator_state = current_state
					local level = current_state == 'failed' and 'warn' or 'info'
					local what = current_state == 'failed' and 'modem_failed' or 'modem_state_changed'
					self.svc:obs_log(level, {
						what = what,
						summary = string.format('%s modem state -> %s', modem_label(self), tostring(current_state)),
						modem = self.name,
						modem_id = self.id,
						modem_suffix = id_suffix(self.id),
						state = current_state,
					})
					if self.summary_fn then self.summary_fn('modem_state_changed') end
				end
			end
		elseif which == 'backoff' then
			self.svc:obs_log('warn', { what = 'autoconnect_retry', modem = self.name, state = current_state })
		end

		-- Act on current_state
		if current_state and self.cfg.autoconnect then
			local err, retry_timeout

			if current_state == 'disabled' then
				local _, err_inner = call_modem_rpc(self.cap, 'enable', {}, REQUEST_TIMEOUT)
				err = err_inner
			elseif current_state == 'failed' then
				local _, err_inner = call_modem_rpc(self.cap, 'listen_for_sim', {}, REQUEST_TIMEOUT)
				err = err_inner
			elseif current_state == 'registered' then
				local _, err_inner, retry_inner = self:_apn_connect()
				err = err_inner
				retry_timeout = retry_inner
				local signal_freq = tonumber(self.cfg.signal_freq) or DEFAULT_SIGNAL_FREQ
				local _, sig_err = modem_set_signal_freq(self.cap, signal_freq)
				if sig_err ~= "" then
					self.svc:obs_log('debug', { what = 'set_signal_freq_failed', modem = self.name, err = sig_err })
				end
			end

			local connection_changed = (connected and current_state ~= STATE_CONNECTED)
				or (not connected and current_state == STATE_CONNECTED)

			if connection_changed then
				connected = current_state == STATE_CONNECTED
				self.connected = connected
				self.conn:retain(t_state_gsm_modem(self.name, 'connected'), connected)
				self:_publish_uplink_state(connected, self.wwan_iface)
				self.svc:obs_event('connection_changed', { modem = self.name, connected = connected })
			end

			if err and err ~= "" then
				backoff = retry_timeout or DEFAULT_RETRY_TIMEOUT
				self.svc:obs_log('error',
					{
						what = 'autoconnect_failed',
						modem = self.name,
						state = current_state,
						err = err,
						retry_after =
							backoff
					})
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
		self.svc:obs_log('debug', { what = 'modem_scope_closed', modem = self.name })
	end)

	local ok, spawn_err = child:spawn(function()
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

	if self.name and self.name ~= "" then
		self.connected = false
		self.conn:retain(t_state_gsm_modem(self.name, 'connected'), false)
		self:_publish_uplink_state(false, self.wwan_iface)
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
	local heartbeat_s = (type(opts.heartbeat_s) == 'number') and opts.heartbeat_s or 30.0

	local svc = base.new(conn, { name = name, env = opts.env })

	svc:obs_state('boot', { at = svc:wall(), ts = svc:now(), state = 'entered' })
	svc:obs_log('debug', 'service start() entered')
	svc:announce({})
	svc:starting()
	svc:spawn_heartbeat(heartbeat_s, 'tick')

	local current_cfg = {}
	local config_ready = false
	local custom_apns = {}
	local apn_store = nil

	-- Transitional APN bridge. GSM is still on its pre-modern service
	-- architecture; keep this surface deliberately small until GSM is migrated.
	-- UI calls GSM-owned APN RPCs, GSM persists custom APNs through the HAL
	-- control-store, and cfg/gsm only points at the store rather than being edited
	-- by UI. The later GSM migration should move this to config_watch, capability
	-- dependency gating and request_owner/scoped_work handling.

	---@type table<string, GsmModem>
	local modems = {}

	local parent_scope = fibers.current_scope()

	local function apn_store_opts_from_config(cfg)
		local spec = cfg and cfg.apn_store or nil
		if spec ~= nil and type(spec) ~= 'table' then return nil, 'invalid_apn_store_config' end
		spec = spec or {}
		local kind = spec.kind or 'control-store'
		if kind ~= 'control-store' then return nil, 'unsupported_apn_store_kind:' .. tostring(kind) end
		return {
			id = spec.id or spec.store_id or apn_store_control.DEFAULT_ID,
			key = spec.key or apn_store_control.DEFAULT_KEY,
		}, nil
	end

	local function publish_apn_state(extra)
		extra = extra or {}
		local store_desc = apn_store and apn_store:describe() or nil
		local payload = {
			schema = 'devicecode.gsm.apns.custom/1',
			count = #custom_apns,
			records = apn_model.redact_list(custom_apns),
			store = store_desc,
			prototype_admin_network_access = true,
			at = svc:wall(),
		}
		svc:_retain(gsm_topics.custom_apns_state(), payload)
		svc:_retain(gsm_topics.apns_status_state(), {
			schema = 'devicecode.gsm.apns.status/1',
			state = extra.state or 'ready',
			ready = extra.ready ~= false,
			reason = extra.reason,
			store = store_desc,
			count = #custom_apns,
			at = svc:wall(),
		})
	end

	local function publish_gsm_capability()
		svc:_retain(gsm_topics.cap_status('main'), {
			schema = 'devicecode.cap.status/1',
			state = 'available',
			available = true,
			methods = gsm_topics.apn_methods(),
		})
		svc:_retain(gsm_topics.cap_meta('main'), {
			schema = 'devicecode.cap.meta/1',
			class = 'gsm',
			id = 'main',
			methods = gsm_topics.apn_methods(),
		})
	end

	local function open_apn_store_for_config(cfg)
		local opts, err = apn_store_opts_from_config(cfg)
		if not opts then
			apn_store = nil
			custom_apns = {}
			svc.custom_apns = custom_apns
			publish_apn_state({ state = 'unavailable', ready = false, reason = err })
			return nil, err
		end
		apn_store = apn_store_control.new(conn, opts)
		local records, lerr = perform(apn_store:load_op())
		if not records then
			custom_apns = {}
			svc.custom_apns = custom_apns
			publish_apn_state({ state = 'degraded', ready = false, reason = lerr or 'apn_store_load_failed' })
			return nil, lerr or 'apn_store_load_failed'
		end
		custom_apns = records
		svc.custom_apns = custom_apns
		publish_apn_state({ state = 'ready', ready = true })
		return true, nil
	end

	local function signal_all_modems()
		for _, modem in pairs(modems) do
			modem:_signal_config_change()
		end
	end

	local function replace_custom_apns(records)
		if not apn_store then return nil, 'apn_store_unavailable' end
		local list, lerr = apn_model.normalise_list(records)
		if not list then return nil, lerr end
		local saved, serr = perform(apn_store:save_op(list))
		if not saved then
			publish_apn_state({ state = 'degraded', ready = false, reason = serr or 'apn_store_save_failed' })
			return nil, serr or 'apn_store_save_failed'
		end
		custom_apns = saved
		svc.custom_apns = custom_apns
		publish_apn_state({ state = 'ready', ready = true })
		signal_all_modems()
		return copy(custom_apns), nil
	end

	local function handle_apn_request(method, payload)
		if method == 'list-custom-apns' then
			return true, copy(custom_apns)
		elseif method == 'replace-custom-apns' then
			local records, perr = apn_model.list_from_payload(payload or {})
			if not records then return false, perr end
			local saved, err = replace_custom_apns(records)
			if not saved then return false, err end
			return true, saved
		elseif method == 'add-custom-apn' then
			local rec, rerr = apn_model.normalise_record((payload and (payload.record or payload)) or {})
			if not rec then return false, rerr end
			local next_list = copy(custom_apns)
			next_list[#next_list + 1] = rec
			local saved, err = replace_custom_apns(next_list)
			if not saved then return false, err end
			return true, saved
		elseif method == 'delete-custom-apn' then
			local idx = tonumber(payload and payload.index)
			if not idx or idx < 1 or idx % 1 ~= 0 or idx > #custom_apns then return false, 'invalid_index' end
			local next_list = copy(custom_apns)
			table.remove(next_list, idx)
			local saved, err = replace_custom_apns(next_list)
			if not saved then return false, err end
			return true, saved
		end
		return false, 'unsupported_apn_method:' .. tostring(method)
	end

	local function bind_apn_endpoints()
		local endpoints = {}
		local function cleanup()
			for _, ep in pairs(endpoints) do bus_cleanup.unbind(conn, ep) end
		end
		parent_scope:finally(cleanup)
		for _, method in ipairs(gsm_topics.apn_methods()) do
			local method_name = method
			local ep, err = bus_cleanup.bind(conn, gsm_topics.rpc(method_name, 'main'), { queue_len = 16 })
			if not ep then return nil, err or ('bind_failed:' .. method_name) end
			endpoints[method_name] = ep
			local ok, spawn_err = parent_scope:spawn(function ()
				while true do
					local req = perform(ep:recv_op())
					if req == nil then return end
					local ok_req, value = handle_apn_request(method_name, req.payload)
					if type(req.reply) == 'function' then
						req:reply({ ok = ok_req == true, reason = value })
					end
				end
			end)
			if not ok then return nil, spawn_err or ('apn_endpoint_spawn_failed:' .. method_name) end
		end
		return true, nil
	end

	parent_scope:finally(function()
		for _, modem in pairs(modems) do
			modem:stop(nil, true)
		end
		local _, primary = fibers.current_scope():status()
		svc:lifecycle('stopped', { ready = false, reason = tostring(primary or 'scope_exit') })
		svc:obs_log('debug', 'service stopped')
	end)

	local function ensure_modem(cap)
		local id = cap.id
		local modem = modems[id]
		if modem then
			return modem
		end

		modem = GsmModem.new(cap, svc)
		modem.summary_fn = function(reason) log_gsm_summary(svc, modems, reason) end
		modems[id] = modem

		local device, device_err = modem_get_field(cap, 'device', REQUEST_TIMEOUT)
		if device_err ~= "" then
			svc:obs_log('debug', { what = 'device_lookup_failed', modem = tostring(id), err = device_err })
		else
			modem.device = tostring(device or "")
		end

		local cfg, modem_name, _ = get_modem_config(current_cfg, id, modem.device)
		modem:apply_config(cfg, modem_name)
		log_modem_detected(modem, {})

		local ok, err = modem:start(parent_scope)
		if not ok then
			svc:obs_log('error', { what = 'modem_start_failed', modem = tostring(id), err = err })
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
		log_gsm_summary(svc, modems, 'modem_removed')
	end

	local cfg_sub = conn:subscribe(t_cfg(name))

	while not config_ready do
		local which, msg, err = perform(op.named_choice({
			cfg = cfg_sub:recv_op(),
			timeout = sleep.sleep_op(REQUEST_TIMEOUT),
		}))

		if which == 'timeout' then
			svc:obs_log('warn', { what = 'waiting_for_config' })
		else
			if not msg then
				svc:obs_log('warn', { what = 'config_sub_closed', err = tostring(err) })
				return
			end
			local cfg_data = msg.payload and msg.payload.data
			if not is_plain_table(cfg_data) then
				svc:obs_log('warn', { what = 'invalid_config_payload' })
			else
				local cfg, cfg_err = normalize_config(cfg_data)
				if cfg_err ~= "" then
					svc:obs_log('warn', { what = 'invalid_config', err = cfg_err })
				else
					current_cfg = cfg
					svc._gsm_expected_roles = derive_expected_roles(cfg)
					config_ready = true
				end
			end
		end
	end

	local store_ok, store_err = open_apn_store_for_config(current_cfg)
	if not store_ok then
		svc:obs_log('warn', { what = 'apn_store_unavailable', err = tostring(store_err) })
	end

	local endpoints_ok, endpoints_err = bind_apn_endpoints()
	if not endpoints_ok then
		svc:obs_log('error', { what = 'apn_endpoint_bind_failed', err = tostring(endpoints_err) })
		error(endpoints_err or 'apn_endpoint_bind_failed', 0)
	end
	publish_gsm_capability()

	local modem_cap_sub = conn:subscribe({ 'cap', 'modem', '+', 'state' })

	svc:obs_event('config_applied', {})
	svc:running()
	svc:obs_log('debug', 'service running')

	while true do
		local choices = {
			cap = modem_cap_sub:recv_op(),
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
			svc:obs_log('debug', { what = 'subscription_closed', err = tostring(err) })
			return
		end

		if which == 'cap' then
			local id = msg.topic and msg.topic[3]
			if msg.payload == 'added' then
				ensure_modem(cap_sdk.new_cap_ref(conn, 'modem', id))
			elseif msg.payload == 'removed' then
				remove_modem(id)
			else
				svc:obs_log('debug',
					{ what = 'unknown_modem_state', modem = tostring(id), state = tostring(msg.payload) })
			end
		elseif which == 'modem_fault' then
			local modem = modems[msg.id]
			if modem then
				svc:obs_log('debug',
					{ what = 'modem_scope_faulted', modem = tostring(msg.id), err = tostring(msg.primary) })
				modem:stop()
			end
		elseif which == 'cfg' then
			local cfg_data = msg.payload and msg.payload.data
			if not is_plain_table(cfg_data) then
				svc:obs_log('debug', { what = 'invalid_config_payload' })
			else
				local updated_cfg, cfg_err = normalize_config(cfg_data)
				if cfg_err ~= "" then
					svc:obs_log('debug', { what = 'invalid_config', err = cfg_err })
				else
					current_cfg = updated_cfg
					svc._gsm_expected_roles = derive_expected_roles(updated_cfg)
					local apn_reload_ok, apn_reload_err = open_apn_store_for_config(current_cfg)
					if not apn_reload_ok then
						svc:obs_log('warn', { what = 'apn_store_reload_failed', err = tostring(apn_reload_err) })
					end
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
