-- services/hal/backends/wired/providers/rtl8380m_http.lua
--
-- Read-only RTL8380M switch provider backed by the firmware HTTP CGI surface.
-- Manufacturer paths, login forms and password encryption stay inside HAL; the
-- Device and Wired services only see semantic wired-provider snapshots.

local cjson = require 'cjson.safe'
local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local file = require 'fibers.io.file'
local exec = require 'fibers.io.exec'

local blob_source = require 'devicecode.blob_source'
local resource = require 'devicecode.support.resource'
local http_sdk = require 'services.http.sdk'
local contract = require 'services.hal.backends.wired.contract'
local tablex = require 'shared.table'

local M = {}
local Provider = {}
Provider.__index = Provider

local EXPONENT_HEX = '10001'
local DEFAULT_TIMEOUT_S = 10
local DEFAULT_HTTP_CAP = 'main'

local function copy(v) return tablex.deep_copy(v) end
local function table_or_empty(v) return type(v) == 'table' and v or {} end

local function default_surfaces()
	return {
		['uplink-cm5'] = {
			provider_surface_id = 'uplink-cm5',
			kind = 'switch-port',
			capabilities = { trunk = true, access = false, poe = false },
			link = { state = 'unknown' },
			attachment = { mode = 'trunk', vlans = {} },
		},
	}
end

local function url_escape_form(s)
	return (tostring(s or ''):gsub('([^%w%-%._~])', function (c)
		return ('%%%02X'):format(string.byte(c))
	end))
end

local function urlencode_b64(s)
	return (tostring(s or ''):gsub('[+/=]', function(c)
		return ('%%%02X'):format(string.byte(c))
	end))
end

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64_encode(s)
	s = tostring(s or '')
	local out = {}
	for i = 1, #s, 3 do
		local b1 = s:byte(i) or 0
		local b2 = s:byte(i + 1) or 0
		local b3 = s:byte(i + 2) or 0
		local n = b1 * 65536 + b2 * 256 + b3
		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64
		out[#out + 1] = B64:sub(c1 + 1, c1 + 1)
		out[#out + 1] = B64:sub(c2 + 1, c2 + 1)
		out[#out + 1] = (i + 1 <= #s) and B64:sub(c3 + 1, c3 + 1) or '='
		out[#out + 1] = (i + 2 <= #s) and B64:sub(c4 + 1, c4 + 1) or '='
	end
	return table.concat(out)
end

local function resolve_env_value(v)
	if type(v) ~= 'string' then return v end
	local name = v:match('^%$ENV:([%w_]+)$')
		or v:match('^env:([%w_]+)$')
		or v:match('^%$([%w_]+)$')
	if name then return os.getenv(name) end
	return v
end

local function normalise_auth(config)
	local auth = table_or_empty(config.auth)
	local username_ref = auth.username_env and ('$' .. tostring(auth.username_env)) or nil
	local password_ref = auth.password_env and ('$' .. tostring(auth.password_env)) or nil
	return {
		username = resolve_env_value(auth.username or config.username or username_ref),
		password = resolve_env_value(auth.password or config.password or password_ref),
		enabled = config.login ~= false and auth.enabled ~= false,
	}
end

local function parse_base_url(url)
	if type(url) ~= 'string' or url == '' then return nil end
	local scheme, rest = url:match('^(https?)://(.+)$')
	if not scheme then return nil end
	local authority, path = rest:match('^([^/]+)(/.*)$')
	if not authority then authority, path = rest, '' end
	local host, port = authority:match('^%[([^%]]+)%]:(%d+)$')
	if not host then host, port = authority:match('^([^:]+):(%d+)$') end
	if not host then host = authority end
	return {
		scheme = scheme,
		host = host,
		port = tonumber(port),
		prefix = path and path:gsub('/+$', '') or '',
	}
end

local function normalise_http_config(config)
	local http = table_or_empty(config.http)
	local base_url = config.base_url or config.url or http.base_url or http.url
	local parsed = parse_base_url(base_url)
	local scheme = http.scheme or config.scheme or (parsed and parsed.scheme) or 'http'
	local host = http.host or config.host or (parsed and parsed.host)
	local port = tonumber(http.port or config.port or (parsed and parsed.port))
	if not port then port = (scheme == 'https') and 443 or 80 end
	return {
		cap_id = http.cap_id or config.http_cap_id or DEFAULT_HTTP_CAP,
		scheme = scheme,
		host = host,
		port = port,
		prefix = http.prefix or config.path_prefix or (parsed and parsed.prefix) or '',
		timeout_s = tonumber(http.timeout_s or config.timeout_s) or DEFAULT_TIMEOUT_S,
		headers = copy(http.headers or config.headers or {}),
	}
end

local function append_dummy(path)
	local sep = path:find('?', 1, true) and '&' or '?'
	return path .. sep .. 'dummy=' .. tostring(math.floor(os.time() * 1000))
end

local function status_ok(status)
	local n = tonumber(status)
	return n ~= nil and n >= 200 and n < 300
end

local function decode_json(body)
	local js, err = cjson.decode(body or '')
	if js == nil then return nil, 'decode error: ' .. tostring(err) end
	return js, nil
end

local function path_join(prefix, path)
	prefix = tostring(prefix or ''):gsub('/+$', '')
	if prefix == '' then return path end
	if path:sub(1, 1) == '/' then return prefix .. path end
	return prefix .. '/' .. path
end

local function is_up_value(v)
	if v == true or v == 1 then return true end
	local s = tostring(v or ''):lower()
	return s == 'up' or s == 'linkup' or s == 'link-up' or s == 'connected' or s == 'on'
end

local function is_down_value(v)
	if v == false or v == 0 then return true end
	local s = tostring(v or ''):lower()
	return s == 'down' or s == 'linkdown' or s == 'link-down' or s == 'disconnected' or s == 'off'
end

local function link_state(port)
	local v = port.link or port.link_state or port.linkStatus or port.status or port.state or port.up
	if is_up_value(v) then return 'up' end
	if is_down_value(v) then return 'down' end
	return 'unknown'
end

local function speed_mbps(port)
	local v = port.speed_mbps or port.speed or port.linkSpeed or port.rate
	if type(v) == 'number' then return v end
	local s = tostring(v or '')
	local n = tonumber(s:match('(%d+)%s*[Gg]'))
	if n then return n * 1000 end
	n = tonumber(s:match('(%d+)%s*[Mm]'))
	if n then return n end
	return tonumber(s)
end

local function port_key(port, idx)
	local raw = port.id or port.port_id or port.port or port.name or port.ifname or idx
	local token = tostring(raw or idx):lower():gsub('^port[%s_%-]*', '')
	token = token:gsub('[^%w%._%-]', '-')
	if token == '' then token = tostring(idx) end
	if token:match('^port%-') then return token end
	return 'port-' .. token
end

local function array_items(t)
	if type(t) ~= 'table' then return function () return nil end end
	if #t > 0 then
		local i = 0
		return function ()
			i = i + 1
			if i <= #t then return i, t[i] end
			return nil
		end
	end
	local keys = tablex.sorted_keys(t)
	local i = 0
	return function ()
		i = i + 1
		local k = keys[i]
		if k ~= nil then return k, t[k] end
		return nil
	end
end

local function poe_by_port(ports_poe)
	local out = {}
	for k, rec in array_items(ports_poe) do
		if type(rec) == 'table' then
			out[port_key(rec, k)] = rec
		end
	end
	return out
end

local function normalise_poe(rec)
	if type(rec) ~= 'table' then return nil end
	local state = rec.state or rec.status or rec.poeStatus or rec.enable
	local watts = tonumber(rec.watts or rec.power or rec.consumption or rec.outputPower) or 0
	local s = tostring(state or ''):lower()
	if s == '' and watts > 0 then s = 'delivering' end
	if s == 'on' or s == 'enabled' then s = watts > 0 and 'delivering' or 'on' end
	if s == 'off' or s == 'disabled' then s = 'off' end
	if s:find('fault', 1, true) or s:find('error', 1, true) then s = 'fault' end
	return {
		state = s ~= '' and s or 'unknown',
		watts = watts,
		limit_watts = tonumber(rec.limit_watts or rec.limit or rec.maxPower),
	}
end

local function merge_surface(base, observed)
	local out = copy(base or {})
	for k, v in pairs(observed or {}) do out[k] = copy(v) end
	return out
end

local function build_surfaces(configured, stats)
	local surfaces = copy(configured or default_surfaces())
	local ports = table_or_empty(stats and stats.ports)
	local poe = poe_by_port(stats and stats.ports_poe)
	local observed_count = 0

	for k, port in array_items(ports) do
		if type(port) == 'table' then
			local id = port_key(port, k)
			observed_count = observed_count + 1
			local poe_rec = poe[id]
			local observed = {
				provider_surface_id = id,
				kind = 'ethernet-port',
				capabilities = { access = true, trunk = true, poe = poe_rec ~= nil },
				link = {
					state = link_state(port),
					speed_mbps = speed_mbps(port),
					duplex = port.duplex or port.linkDuplex,
				},
				attachment = {
					mode = port.mode or port.vlan_mode or 'unknown',
					vlan = port.vlan,
					vlans = port.vlans or port.tagged,
				},
				poe = normalise_poe(poe_rec),
				raw = copy(port),
			}
			surfaces[id] = merge_surface(surfaces[id], observed)
		end
	end

	return surfaces, observed_count
end

local function make_unavailable(self, code, err)
	return {
		ok = false,
		provider_id = self.id,
		mode = self.mode,
		writable = false,
		code = code,
		err = err,
		status = {
			state = 'unavailable',
			available = false,
			mode = self.mode,
			driver = 'rtl8380m_http',
			code = code,
			err = err,
			base_url_configured = self.http.host ~= nil,
		},
		surfaces = copy(self.surfaces),
		topology = copy(self.topology),
		telemetry = copy(self.telemetry),
	}
end

local function write_tmp(scope, label, data, tmpdir)
	local stream, err = file.tmpfile('rw-------', tmpdir)
	if not stream then return nil, label .. '_tmpfile_failed:' .. tostring(err) end
	scope:finally(function (_, status, primary)
		resource.terminate_checked(
			stream,
			primary or status or label .. '_tmpfile_closed',
			label .. '_tmpfile_cleanup_failed'
		)
	end)
	local path = stream:filename()
	if type(path) ~= 'string' or path == '' then return nil, label .. '_tmpfile_path_unavailable' end
	local n, werr = fibers.perform(stream:write_op(data))
	if n == nil then return nil, label .. '_write_failed:' .. tostring(werr) end
	local ok, ferr = fibers.perform(stream:flush_op())
	if ok == nil then return nil, label .. '_flush_failed:' .. tostring(ferr) end
	return path, nil
end

local function run_checked(cmd, label)
	local out, status, code, signal, err = fibers.perform(cmd:combined_output_op())
	if status == 'exited' and code == 0 then return out or '', nil end
	if status == 'signalled' then return nil, label .. '_signalled:' .. tostring(signal) end
	return nil, label .. '_failed:' .. tostring(err or out or code or status)
end

local function encrypt_password_op(self, modulus_hex, password)
	return fibers.run_scope_op(function (scope)
		local asn1 = ([[
asn1=SEQUENCE:pubkey
[pubkey]
modulus=INTEGER:0x%s
pubexp=INTEGER:0x%s
]]):format(tostring(modulus_hex or ''), EXPONENT_HEX)

		local asn1_path, aerr = write_tmp(scope, 'rtl8380m_asn1', asn1, self.tmpdir)
		if not asn1_path then return nil, aerr end
		local der_path, derr = write_tmp(scope, 'rtl8380m_der', '', self.tmpdir)
		if not der_path then return nil, derr end
		local pem_path, perr = write_tmp(scope, 'rtl8380m_pem', '', self.tmpdir)
		if not pem_path then return nil, perr end

		local _, err = run_checked(self.exec.command(
			'openssl', 'asn1parse', '-genconf', asn1_path, '-out', der_path, '-noout'
		), 'openssl_asn1parse')
		if err then return nil, err end

		_, err = run_checked(self.exec.command(
			'openssl', 'rsa', '-RSAPublicKey_in', '-inform', 'DER', '-in', der_path, '-out', pem_path, '-pubout'
		), 'openssl_rsa')
		if err then return nil, err end

		local cmd = self.exec.command {
			'openssl', 'pkeyutl', '-encrypt', '-inkey', pem_path, '-pubin',
			'-pkeyopt', 'rsa_padding_mode:pkcs1',
			stdin = 'pipe',
			stdout = 'pipe',
			stderr = 'null',
		}
		local stdin, serr = cmd:stdin_stream()
		if not stdin then return nil, 'openssl_pkeyutl_stdin_failed:' .. tostring(serr) end
		local n, werr = fibers.perform(stdin:write_op(tostring(password or '')))
		if n == nil then return nil, 'openssl_pkeyutl_password_write_failed:' .. tostring(werr) end
		resource.terminate_checked(stdin, 'password_written', 'openssl_pkeyutl_stdin_cleanup_failed')

		local ciphertext, status, code, signal, cerr = fibers.perform(cmd:output_op())
		if status ~= 'exited' or code ~= 0 then
			if status == 'signalled' then return nil, 'openssl_pkeyutl_signalled:' .. tostring(signal) end
			return nil, 'openssl_pkeyutl_failed:' .. tostring(cerr or code or status)
		end
		if type(ciphertext) ~= 'string' or ciphertext == '' then return nil, 'openssl_pkeyutl_empty_output' end
		return urlencode_b64(base64_encode(ciphertext)), nil
	end):wrap(function (status, report, encoded, err)
		if status ~= 'ok' then return nil, err or (report and report.primary) or status end
		return encoded, err
	end)
end

function M.new(config, opts)
	config = config or {}
	opts = opts or {}
	local http = normalise_http_config(config)
	local auth = normalise_auth(config)
	return setmetatable({
		id = config.id or config.capability_id or 'switch-main',
		mode = config.mode or 'read_only',
		http = http,
		auth = auth,
		telemetry = copy(config.telemetry or {}),
		surfaces = copy(config.surfaces or default_surfaces()),
		topology = copy(config.topology or {}),
		logger = opts.logger,
		conn = opts.conn,
		http_ref = opts.http_ref or config.http_ref,
		exec = opts.exec or exec,
		tmpdir = opts.tmpdir or config.tmpdir or os.getenv('TMPDIR') or '/tmp',
	}, Provider), nil
end

function Provider:_http_ref()
	if self.http_ref then return self.http_ref end
	if not self.conn then return nil end
	return http_sdk.new_ref(self.conn, self.http.cap_id)
end

function Provider:_uri(path)
	local h = self.http
	if type(h.host) ~= 'string' or h.host == '' then return nil, 'switch host not configured' end
	local authority = h.host
	if h.host:find(':', 1, true) and h.host:sub(1, 1) ~= '[' then authority = '[' .. h.host .. ']' end
	local default_port = (h.scheme == 'https') and 443 or 80
	if tonumber(h.port) and tonumber(h.port) ~= default_port then
		authority = authority .. ':' .. tostring(h.port)
	end
	return h.scheme .. '://' .. authority .. path_join(h.prefix, path), nil
end

function Provider:_request_json_op(method, path, body, headers)
	return op.guard(function ()
		local ref = self:_http_ref()
		if not ref then return op.always(nil, 'http capability unavailable') end
		local uri, uerr = self:_uri(path)
		if not uri then return op.always(nil, uerr) end
		local req_headers = copy(self.http.headers or {})
		for k, v in pairs(headers or {}) do req_headers[k] = v end
		local args = {
			uri = uri,
			method = method or 'GET',
			headers = req_headers,
		}
		if body ~= nil then args.body_source = blob_source.from_string(body) end

		return ref:open_exchange_op(args, { timeout = self.http.timeout_s }):wrap(function (reply, err)
			if not reply then return nil, err end
			local exchange = reply.exchange or reply
			if not exchange or type(exchange.read_body_as_string_op) ~= 'function' then
				return nil, 'http exchange handle unavailable'
			end
			local response_body, rerr = fibers.perform(exchange:read_body_as_string_op())
			local status = exchange.status and exchange:status() or nil
			if exchange.shutdown_op then
				local ok = fibers.perform(exchange:shutdown_op())
				if ok == nil and not rerr then rerr = 'http exchange shutdown failed' end
			elseif exchange.terminate then
				exchange:terminate('rtl8380m_http_done')
			end
			if rerr then return nil, rerr end
			if not status_ok(status) then return nil, 'http status ' .. tostring(status) end
			return decode_json(response_body)
		end)
	end)
end

function Provider:_get_cgi_json_op(cmd, use_dummy)
	local path = '/cgi/get.cgi?cmd=' .. url_escape_form(cmd)
	if use_dummy then path = append_dummy(path) end
	return self:_request_json_op('GET', path)
end

function Provider:_post_cgi_json_op(path, payload, headers)
	headers = headers or {}
	headers['Content-Type'] = headers['Content-Type'] or 'application/x-www-form-urlencoded; charset=UTF-8'
	headers['X-Requested-With'] = headers['X-Requested-With'] or 'XMLHttpRequest'
	headers['Content-Length'] = tostring(#payload)
	return self:_request_json_op('POST', path, payload, headers)
end

function Provider:_login_op()
	if self.auth.enabled == false then return op.always(true, nil) end
	if not self.auth.username or not self.auth.password then return op.always(true, nil) end

	return fibers.run_scope_op(function ()
		local js, err = fibers.perform(self:_get_cgi_json_op('home_login', false))
		if not js then return false, 'failed to fetch modulus: ' .. tostring(err) end
		local modulus = js.data and js.data.modulus
		if type(modulus) ~= 'string' or modulus == '' then return false, 'login modulus missing' end

		local encoded, perr = fibers.perform(encrypt_password_op(self, modulus, self.auth.password))
		if not encoded then return false, 'encrypt error: ' .. tostring(perr) end

		local payload = ('_ds=1&username=%s&password=%s&_de=1'):format(
			url_escape_form(self.auth.username),
			encoded
		)
		local _, post_err = fibers.perform(self:_post_cgi_json_op('/cgi/set.cgi?cmd=home_loginAuth', payload))
		if post_err then return false, post_err end

		for _ = 1, 10 do
			local st_js, serr = fibers.perform(self:_get_cgi_json_op('home_loginStatus', false))
			if not st_js then return false, serr end
			local status = st_js.data and st_js.data.status
			if status == 'ok' then return true, nil end
			if status == 'fail' then return false, 'login failed incorrect credentials' end
			fibers.perform(sleep.sleep_op(1))
		end
		return false, 'login timeout'
	end):wrap(function (status, report, ok, err)
		if status ~= 'ok' then return false, err or (report and report.primary) or status end
		return ok, err
	end)
end

function Provider:_stats_op()
	return fibers.run_scope_op(function ()
		local stats = {
			system = { curr_time = 0, mem = 0, cpu = 0, power = 0, temp = 0 },
			ports = {},
			ports_poe = {},
		}

		local js, err = fibers.perform(self:_get_cgi_json_op('sys_sysTime', true))
		if not js then return nil, err end
		stats.system.curr_time = js.data and js.data.sysCurrTime or nil

		js, err = fibers.perform(self:_get_cgi_json_op('sys_cpumem', true))
		if not js then return nil, err end
		stats.system.cpu = js.data and js.data.cpu or nil
		stats.system.mem = js.data and js.data.mem or nil

		js, err = fibers.perform(self:_get_cgi_json_op('panel_info', true))
		if not js then return nil, err end
		stats.ports = js.data and js.data.ports or {}

		js, err = fibers.perform(self:_get_cgi_json_op('poe_poe', true))
		if not js then return nil, err end
		stats.ports_poe = js.data and js.data.ports or {}
		stats.system.power = js.data and js.data.devPower or nil
		stats.system.temp = js.data and js.data.devTemp or nil

		return stats, nil
	end):wrap(function (status, report, stats, err)
		if status ~= 'ok' then return nil, err or (report and report.primary) or status end
		return stats, err
	end)
end

function Provider:_snapshot_from_stats(stats)
	local surfaces, observed_count = build_surfaces(self.surfaces, stats)
	local telemetry = copy(self.telemetry or {})
	telemetry.system = copy(stats.system or {})
	telemetry.observed_ports = observed_count

	local topology = copy(self.topology or {})
	topology.provider = 'rtl8380m_http'
	topology.port_count = observed_count

	return {
		ok = true,
		provider_id = self.id,
		mode = self.mode,
		writable = false,
		status = {
			state = 'available',
			available = true,
			mode = self.mode,
			driver = 'rtl8380m_http',
			base_url_configured = self.http.host ~= nil,
			host = self.http.host,
		},
		surfaces = surfaces,
		topology = topology,
		telemetry = telemetry,
	}
end

function Provider:fetch_snapshot_op(_req)
	return op.guard(function ()
		if type(self.http.host) ~= 'string' or self.http.host == '' then
			return op.always(make_unavailable(self, 'host_not_configured', 'switch host not configured'))
		end
		return fibers.run_scope_op(function ()
			local logged_in, lerr = fibers.perform(self:_login_op())
			if logged_in ~= true then return make_unavailable(self, 'login_failed', lerr or 'login failed') end
			local stats, serr = fibers.perform(self:_stats_op())
			if not stats then return make_unavailable(self, 'stats_failed', serr or 'stats failed') end
			return self:_snapshot_from_stats(stats)
		end):wrap(function (status, report, snapshot)
			if status ~= 'ok' then
				return make_unavailable(self, 'snapshot_failed', snapshot or (report and report.primary) or status)
			end
			return snapshot
		end)
	end)
end

function Provider:snapshot_op(req) return self:fetch_snapshot_op(req) end
function Provider:watch_op(req) return self:fetch_snapshot_op(req) end
function Provider:apply_attachments_op(_req) return op.always(contract.read_only('apply_attachments')) end
function Provider:set_poe_op(_req) return op.always(contract.read_only('set_poe')) end
function Provider:bounce_op(_req) return op.always(contract.read_only('bounce')) end
function Provider:terminate(_reason) return true end

M._test = {
	build_surfaces = build_surfaces,
	normalise_http_config = normalise_http_config,
	resolve_env_value = resolve_env_value,
}

return M
