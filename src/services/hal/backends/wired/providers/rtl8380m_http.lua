-- services/hal/backends/wired/providers/rtl8380m_http.lua
--
-- Read-only HTTP provider for RTL8380-family PoE/VLAN switches.
--
-- The provider keeps the manufacturer HTTP/CGI/RSA-login details below HAL and
-- returns provider-shaped raw observations for the Wired service.  It deliberately
-- leaves writes unsupported until the control path has dedicated tests against
-- the switch UI's set.cgi forms.

local fibers = require 'fibers'
local op = require 'fibers.op'
local contract = require 'services.hal.backends.wired.contract'
local tablex = require 'shared.table'
local blob_source = require 'devicecode.blob_source'

local ok_cjson, cjson = pcall(require, 'cjson.safe')
if not ok_cjson then cjson = require 'cjson' end

local M = {}
local Provider = {}
Provider.__index = Provider

local DRIVER = 'rtl8380m_http'
local USER_AGENT = 'devicecode-rtl8380m-http/1 lua-http'

local READ_COMMANDS = {
	'home_main',
	'panel_info',
	'sys_sysinfo',
	'port_port',
	'vlan_create',
	'vlan_conf',
	'vlan_port',
	'vlan_membership',
	'poe_poe',
	'lldp_local',
	'lldp_neighbor',
	'sys_cpumem',
	'rmon_statistics',
}

local VLAN_MODE = {
	[0] = 'hybrid',
	[1] = 'access',
	[2] = 'trunk',
	[3] = 'tunnel',
}

local VLAN_ACCEPT_FRAME = {
	[0] = 'all',
	[1] = 'tag_only',
	[2] = 'untag_only',
}

local VLAN_MEMBERSHIP = {
	[0] = 'excluded',
	[2] = 'tagged',
	[3] = 'untagged',
}

local function copy(v) return tablex.deep_copy(v) end

local function trim(s)
	return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function getenv_ref(v)
	if type(v) ~= 'string' then return v end
	local name = v:match('^%$([%w_]+)$')
	if name then return os.getenv(name) end
	return v
end

local function ensure_base_url(url)
	if type(url) ~= 'string' or url == '' then return nil, 'base_url is required' end
	if not url:match('^https?://') then return nil, 'base_url must include http:// or https:// scheme' end
	if not url:match('/$') then return nil, 'base_url must end with /' end
	return url, nil
end

local function parse_origin(url)
	local scheme, hostport = tostring(url or ''):match('^(https?)://([^/]+)')
	if not scheme then return nil end
	return scheme .. '://' .. hostport
end

local function cgi_url(base_url, kind, cmd, dummy)
	local origin = assert(parse_origin(base_url), 'invalid switch base URL')
	local url = origin .. '/cgi/' .. kind .. '.cgi?cmd=' .. tostring(cmd or '')
	if dummy then url = url .. '&dummy=' .. tostring(dummy) end
	return url
end

local function shell_quote(s)
	s = tostring(s or '')
	return "'" .. s:gsub("'", "'\\''") .. "'"
end




local CookieJar = {}
CookieJar.__index = CookieJar

function CookieJar.new(initial)
	local self = setmetatable({ values = {}, order = {} }, CookieJar)
	for name, value in pairs(initial or {}) do
		name = tostring(name or '')
		if name ~= '' then
			self.order[#self.order + 1] = name
			self.values[name] = tostring(value or '')
		end
	end
	return self
end

function CookieJar:set(name, value)
	name = trim(name or '')
	if name == '' then return end
	if self.values[name] == nil then self.order[#self.order + 1] = name end
	self.values[name] = tostring(value or '')
end

function CookieJar:update(set_cookie)
	if type(set_cookie) ~= 'string' or set_cookie == '' then return end
	local first = set_cookie:match('^%s*([^;]+)')
	if not first then return end
	local name, value = first:match('^%s*([^=]+)=(.*)$')
	if not name then return end
	self:set(name, value or '')
end

function CookieJar:header()
	local out = {}
	for _, name in ipairs(self.order) do
		if self.values[name] ~= nil then out[#out + 1] = name .. '=' .. self.values[name] end
	end
	return table.concat(out, '; ')
end

function CookieJar:names()
	local out = {}
	for _, name in ipairs(self.order) do out[#out + 1] = name end
	return out
end

local function header_values(headers, name)
	name = tostring(name or ''):lower()
	local values = {}
	if type(headers) == 'table' then
		local v = headers[name]
		if type(v) == 'table' then
			for i = 1, #v do values[#values + 1] = tostring(v[i] or '') end
		elseif v ~= nil then
			values[#values + 1] = tostring(v)
		else
			for k, hv in pairs(headers) do
				if tostring(k):lower() == name then values[#values + 1] = tostring(hv or '') end
			end
		end
	end
	return values
end

local function request(self, method, url, body, extra_headers)
	if not self.http_ref or type(self.http_ref.exchange_op) ~= 'function' then
		return nil, 'http capability ref not configured'
	end

	local req_headers = {
		['user-agent'] = USER_AGENT,
		accept = 'application/json,text/plain,*/*',
		connection = 'close',
	}
	local cookie = self.jar:header()
	if cookie ~= '' then req_headers.cookie = cookie end
	for k, v in pairs(extra_headers or {}) do req_headers[k] = tostring(v) end

	local sink = blob_source.to_memory()
	local args = {
		uri = url,
		method = tostring(method or 'GET'):upper(),
		headers = req_headers,
		response_sink = sink,
	}
	if body ~= nil then args.body_source = blob_source.from_string(body or '') end
	if self.response_parser and tostring(url):match('/cgi/[gs]et%.cgi%?') then
		args.response_parser = self.response_parser
		args.timeout_s = self.timeout_s
		args.max_response_bytes = self.max_response_bytes
	end

	local reply, err = fibers.perform(self.http_ref:exchange_op(args, { timeout = self.timeout_s }))
	if not reply then return nil, err end
	local result = reply.result or reply
	local status = tonumber(result and result.status or 0) or 0
	local headers = result and result.headers or {}
	for _, sc in ipairs(header_values(headers, 'set-cookie')) do self.jar:update(sc) end
	return { ok = true, status = status, headers = headers, body = sink:result() }
end

local function json_decode(body)
	local t, err = cjson.decode(tostring(body or ''))
	if type(t) ~= 'table' then return nil, err or 'invalid JSON response' end
	return t, nil
end

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64(data)
	data = tostring(data or '')
	local data_len = #data
	return ((data:gsub('.', function(x)
		local r, b = '', x:byte()
		for i = 8, 1, -1 do r = r .. ((b % 2 ^ i - b % 2 ^ (i - 1) > 0) and '1' or '0') end
		return r
	end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
		if #x < 6 then return '' end
		local c = 0
		for i = 1, 6 do c = c + ((x:sub(i, i) == '1') and 2 ^ (6 - i) or 0) end
		return b64chars:sub(c + 1, c + 1)
	end) .. ({ '', '==', '=' })[data_len % 3 + 1])
end

local function json_escape(s)
	s = tostring(s or '')
	return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
end

local function json_empty_object_at_key(key)
	return '{' .. json_escape(key) .. ':{}}'
end

local function form_encode(fields)
	local function enc(s)
		s = tostring(s or '')
		s = s:gsub('\n', '\r\n')
		s = s:gsub('([^%w%-_%.~ ])', function(c) return string.format('%%%02X', c:byte()) end)
		return s:gsub(' ', '+')
	end
	local keys, out = {}, {}
	for k in pairs(fields or {}) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do out[#out + 1] = enc(k) .. '=' .. enc(fields[k]) end
	return table.concat(out, '&')
end

local function write_file_raw(path, data)
	local f = assert(io.open(path, 'wb'))
	f:write(data or '')
	f:close()
end

local function read_file(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local data = f:read('*a')
	f:close()
	return data
end

local function der_len(n)
	if n < 128 then return string.char(n) end
	local bytes = {}
	while n > 0 do table.insert(bytes, 1, string.char(n % 256)); n = math.floor(n / 256) end
	return string.char(0x80 + #bytes) .. table.concat(bytes)
end

local function der(tag, content) return string.char(tag) .. der_len(#(content or '')) .. (content or '') end
local function hex_to_bin(hex)
	hex = tostring(hex or ''):gsub('%s+', ''):gsub(':', '')
	if #hex % 2 == 1 then hex = '0' .. hex end
	return (hex:gsub('..', function(cc) return string.char(tonumber(cc, 16) or 0) end))
end
local function der_integer_bin(b)
	b = tostring(b or '')
	while #b > 1 and b:byte(1) == 0 do b = b:sub(2) end
	if #b == 0 then b = string.char(0) end
	if b:byte(1) >= 0x80 then b = string.char(0) .. b end
	return der(0x02, b)
end
local function der_integer_from_hex(hex) return der_integer_bin(hex_to_bin(hex)) end
local function der_integer_from_number(n)
	local bytes = {}
	repeat table.insert(bytes, 1, string.char(n % 256)); n = math.floor(n / 256) until n == 0
	return der_integer_bin(table.concat(bytes))
end
local function pem_wrap(label, der_bytes)
	local b, lines = base64(der_bytes), {}
	for i = 1, #b, 64 do lines[#lines + 1] = b:sub(i, i + 63) end
	return '-----BEGIN ' .. label .. '-----\n' .. table.concat(lines, '\n') .. '\n-----END ' .. label .. '-----\n'
end
local function rsa_public_key_pem(modulus_hex)
	local rsa_pub = der(0x30, der_integer_from_hex(modulus_hex) .. der_integer_from_number(65537))
	local alg_id = der(0x30, der(0x06, hex_to_bin('2A864886F70D010101')) .. der(0x05, ''))
	return pem_wrap('PUBLIC KEY', der(0x30, alg_id .. der(0x03, string.char(0) .. rsa_pub)))
end

local function openssl_encrypt_b64(self, modulus_hex, plaintext)
	local prefix = os.tmpname()
	local pub_path, in_path, out_path = prefix .. '.pub.pem', prefix .. '.plain', prefix .. '.cipher'
	write_file_raw(pub_path, rsa_public_key_pem(modulus_hex))
	write_file_raw(in_path, plaintext or '')
	local openssl = shell_quote(self.openssl_bin)
	local cmd = table.concat({ openssl, 'pkeyutl', '-encrypt', '-pubin', '-inkey', shell_quote(pub_path), '-pkeyopt', 'rsa_padding_mode:pkcs1', '-in', shell_quote(in_path), '-out', shell_quote(out_path), '2>/dev/null' }, ' ')
	local ok = os.execute(cmd)
	if not (ok == true or ok == 0) then
		cmd = table.concat({ openssl, 'rsautl', '-encrypt', '-pubin', '-pkcs', '-inkey', shell_quote(pub_path), '-in', shell_quote(in_path), '-out', shell_quote(out_path), '2>/dev/null' }, ' ')
		ok = os.execute(cmd)
	end
	local cipher = read_file(out_path)
	os.remove(pub_path); os.remove(in_path); os.remove(out_path)
	if not (ok == true or ok == 0) or not cipher or cipher == '' then return nil, 'openssl_rsa_encrypt_failed' end
	return base64(cipher)
end

local function response_status_ok(body)
	return tostring(body or ''):find('"status"%s*:%s*"ok"') ~= nil
end

local function login(self)
	if self.disable_login or self.logged_in then return true, nil end
	if not self.username or not self.password then return false, 'switch username/password not configured' end
	self.jar:set('cookie_language', 'defLang_en')
	local info_url = cgi_url(self.base_url, 'get', 'home_login')
	local info, err = request(self, 'GET', info_url)
	if not info or info.status ~= 200 then return false, err or ('home_login HTTP ' .. tostring(info and info.status)) end
	local info_json, jerr = json_decode(info.body)
	if not info_json then return false, 'home_login invalid JSON: ' .. tostring(jerr) end
	local modulus = info_json.data and info_json.data.modulus
	if not modulus then return false, 'home_login response missing RSA modulus' end
	local encrypted, enc_err = openssl_encrypt_b64(self, modulus, self.password)
	if not encrypted then return false, enc_err end
	local form_data = '_ds=1&' .. form_encode({ username = self.username, password = encrypted }) .. '&_de=1'
	local auth_url = cgi_url(self.base_url, 'set', 'home_loginAuth', os.time())
	local origin = parse_origin(self.base_url)
	local login_html = origin .. '/login.html'
	local bodies = {
		{ body = json_empty_object_at_key(form_data), content_type = 'application/json' },
		{ body = form_data, content_type = 'application/json' },
		{ body = form_data, content_type = 'application/x-www-form-urlencoded' },
	}
	for _, candidate in ipairs(bodies) do
		local headers = {
			['content-type'] = candidate.content_type,
			['accept'] = 'application/json, text/javascript, */*; q=0.01',
			['x-requested-with'] = 'XMLHttpRequest',
			['referer'] = login_html,
			['origin'] = origin,
		}
		request(self, 'POST', auth_url, candidate.body, headers)
		for _ = 1, 6 do
			local status = request(self, 'GET', cgi_url(self.base_url, 'get', 'home_loginStatus'))
			if status and response_status_ok(status.body) then self.logged_in = true; return true, nil end
		end
	end
	return false, 'RTL8380 RSA login was not confirmed'
end

local function get_cmd(self, cmd)
	local url = cgi_url(self.base_url, 'get', cmd)
	if cmd == 'rmon_statistics' then url = url .. '&time=0' end
	local r, err = request(self, 'GET', url)
	if not r then return nil, err end
	if r.status ~= 200 then return nil, ('%s HTTP %s'):format(cmd, tostring(r.status)) end
	local parsed, perr = json_decode(r.body)
	if not parsed then return nil, cmd .. ' invalid JSON: ' .. tostring(perr) end
	if parsed.logout then return nil, cmd .. ' returned logout=' .. tostring(parsed.logout) .. ' reason=' .. tostring(parsed.reason) end
	return parsed.data or parsed, nil
end

local function parse_speed_mbps(v)
	if v == nil then return nil end
	local n = tonumber(tostring(v):match('(%d+)'))
	return n
end

local function parse_media(v, panel)
	local s = tostring(v or ''):lower()
	if panel and panel.media == 'fiber' then return 'fiber' end
	if s:find('fiber', 1, true) then return 'fiber' end
	if s:find('copper', 1, true) then return 'copper' end
	return nil
end

local function parse_vlan_membership_string(s)
	local out = {}
	s = tostring(s or '')
	for token in s:gmatch('%S+') do
		local vlan, flags = token:match('^(%d+)([A-Z]+)$')
		if vlan then
			local rec = { vlan = tonumber(vlan), raw = token }
			if flags:find('T', 1, true) then rec.tagged = true end
			if flags:find('U', 1, true) then rec.untagged = true end
			if flags:find('F', 1, true) then rec.forbidden = true end
			if flags:find('P', 1, true) then rec.pvid = true end
			out[#out + 1] = rec
		end
	end
	return out
end

local function vlans_from_membership(parsed)
	local tagged, untagged, all = {}, {}, {}
	for _, rec in ipairs(parsed or {}) do
		if rec.vlan and rec.vlan ~= 4095 and not rec.forbidden then
			all[#all + 1] = rec.vlan
			if rec.tagged then tagged[#tagged + 1] = rec.vlan end
			if rec.untagged then untagged[#untagged + 1] = rec.vlan end
		end
	end
	return all, tagged, untagged
end

local function is_lag_name(name) return tostring(name or ''):match('^LAG%d+$') ~= nil end

local function percent(v)
	local n = tonumber(v)
	if n == nil then return nil end
	return n
end

local function parse_runtime(sys_cpumem)
	sys_cpumem = sys_cpumem or {}
	return {
		cpu = {
			utilisation_pct = percent(sys_cpumem.cpu),
		},
		memory = {
			utilisation_pct = percent(sys_cpumem.mem),
		},
	}
end

local function parse_power(poe)
	poe = poe or {}
	return {
		poe = {
			total_power_mw = poe.devPower,
			total_power_w = type(poe.devPower) == 'number' and poe.devPower / 1000 or nil,
			temperature_c = poe.devTemp,
		},
	}
end

local function parse_surface_counters(row)
	if type(row) ~= 'table' then return nil end
	local errors = 0
	local has_error = false
	for _, key in ipairs({ 'CRCAlignErr', 'undersizePkts', 'oversizePkts', 'fragments', 'jabbers', 'collisions' }) do
		local n = tonumber(row[key])
		if n then errors = errors + n; has_error = true end
	end
	return {
		rx = {
			bytes = tonumber(row.bytesRec),
			packets = tonumber(row.pktsRec),
			drops = tonumber(row.dropEvents),
			errors = has_error and errors or nil,
			broadcast_packets = tonumber(row.bPktsRec),
			multicast_packets = tonumber(row.mPktsRec),
		},
		size_buckets = {
			frames_64 = tonumber(row.frames64B),
			frames_65_127 = tonumber(row.frames65127B),
			frames_128_255 = tonumber(row.frames128255B),
			frames_256_511 = tonumber(row.frames256511B),
			frames_512_1023 = tonumber(row.frames5121023B),
			frames_over_1024 = tonumber(row.framesOver1024B),
		},
	}
end

local function build_surfaces(data)
	local home = data.home_main or {}
	local ports = home.ports or {}
	local panel_ports = (data.panel_info or {}).ports or {}
	local port_rows = (data.port_port or {}).ports or {}
	local vlan_conf = (data.vlan_conf or {}).ports or {}
	local vlan_port = (data.vlan_port or {}).ports or {}
	local vlan_membership = (data.vlan_membership or {}).ports or {}
	local poe_ports = (data.poe_poe or {}).ports or {}
	local rmon_ports = (data.rmon_statistics or {}).ports or {}
	local surfaces = {}

	for i, port in ipairs(ports) do
		local name = tostring(port.port or port.name or ('port-' .. i))
		local panel = panel_ports[i]
		local prow = port_rows[i]
		local vconf = vlan_conf[i]
		local vp = vlan_port[i]
		local vm = vlan_membership[i]
		local poe = poe_ports[i]
		local rmon = rmon_ports[i]
		local media = parse_media(prow and prow.type, panel)
		local membership = parse_vlan_membership_string((vm and (vm.operVlans or vm.adminVlans)) or '')
		local vlans, tagged, untagged = vlans_from_membership(membership)
		local mode = VLAN_MODE[(vp and vp.mode) or (vm and vm.mode) or (vconf and vconf.mode)]
		local pvid = vp and vp.pvid
		if pvid == nil and vconf and vconf.pvid then pvid = (data.vlan_conf and data.vlan_conf.vlan) or 1 end
		local link_up = (panel and panel.linkup) or (prow and prow.operStatus)
		local speed = parse_speed_mbps((panel and panel.speed) or (prow and prow.operSpeed))
		local duplex
		if panel and panel.dupFull ~= nil then duplex = panel.dupFull and 'full' or 'half'
		elseif prow and type(prow.operDuplex) == 'string' and prow.operDuplex:lower():find('full') then duplex = 'full'
		elseif prow and type(prow.operDuplex) == 'string' and prow.operDuplex:lower():find('half') then duplex = 'half' end

		surfaces[name] = {
			provider_surface_id = name,
			kind = is_lag_name(name) and 'lag' or 'switch-port',
			capabilities = {
				trunk = mode == 'trunk' or mode == 'hybrid',
				access = mode == 'access' or mode == 'hybrid',
				poe = poe ~= nil,
			},
			link = {
				state = link_up and 'up' or 'down',
				speed_mbps = speed,
				duplex = duplex,
				auto_negotiation = panel and panel.autoNego or nil,
				media = media,
			},
			attachment = {
				mode = mode,
				pvid = pvid,
				vlans = vlans,
				tagged_vlans = tagged,
				untagged_vlans = untagged,
				accept_frame_type = vp and VLAN_ACCEPT_FRAME[vp.accFrameType] or nil,
				ingress_filter = vp and vp.ingressFilter or nil,
				uplink = vp and vp.uplink or nil,
				tpid = vp and vp.tpid or nil,
				admin_vlans_raw = vm and vm.adminVlans or nil,
				oper_vlans_raw = vm and vm.operVlans or nil,
				oper_vlans = membership,
				vlan_membership = vconf and VLAN_MEMBERSHIP[vconf.membership] or nil,
				forbidden = vconf and vconf.forbidden or nil,
			},
			raw = {
				panel_info = panel,
				port_port = prow,
				vlan_conf = vconf,
				vlan_port = vp,
				vlan_membership = vm,
				poe_poe = poe,
				rmon_statistics = rmon,
			},
		}

		local counters = parse_surface_counters(rmon)
		if counters then surfaces[name].counters = counters end

		if poe then
			surfaces[name].poe = {
				enabled = poe.portEnable == true,
				state = poe.portStatus and 'delivering' or 'off',
				delivering = poe.portStatus == true,
				type = poe.portType,
				level = poe.portLevel,
				power_limit_mw = poe.portPowerLimit,
				watchdog = poe.watchDog == true,
			}
		end
	end

	return surfaces
end

local function build_snapshot(self, data)
	local sys = data.sys_sysinfo or {}
	local home = data.home_main or {}
	local poe = data.poe_poe or {}
	local identity = {
		model = home.model or home.title,
		hostname = sys.hostname,
		mac = sys.sysMac,
		firmware = sys.fwVer,
		firmware_date = sys.fwDate,
		loader = sys.loaderVer,
		loader_date = sys.loaderDate,
		serial = sys.syssn,
		management_ipv4 = sys.currIpv4,
		management_ipv6 = sys.currIpv6,
	}
	return {
		ok = true,
		provider_id = self.id,
		mode = self.mode,
		writable = false,
		status = {
			state = 'available',
			available = true,
			mode = self.mode,
			driver = DRIVER,
			base_url = self.base_url,
			login = self.logged_in and 'confirmed' or (self.disable_login and 'disabled' or 'attempted'),
		},
		identity = identity,
		surfaces = build_surfaces(data),
		topology = {
			lldp_local = data.lldp_local,
			lldp_neighbor = data.lldp_neighbor,
		},
		runtime = parse_runtime(data.sys_cpumem),
		power = parse_power(poe),
		raw = self.include_raw and data or nil,
	}
end

local function require_http_config(config)
	local http = config and config.http or nil
	if type(http) ~= 'table' then return nil, 'http table is required' end
	if type(http.capability) ~= 'string' or http.capability == '' then return nil, 'http.capability is required' end
	if http.response_parser ~= 'legacy-http1-close' then return nil, 'http.response_parser must be legacy-http1-close' end
	local max_response_bytes = tonumber(http.max_response_bytes) or (1024 * 1024)
	if max_response_bytes <= 0 then return nil, 'http.max_response_bytes must be positive when supplied' end
	return { capability = http.capability, response_parser = http.response_parser, max_response_bytes = max_response_bytes }, nil
end


local CONFIG_FIELDS = {
	provider = true,
	mode = true,
	base_url = true,
	username = true,
	password = true,
	timeout_s = true,
	poll_interval_s = true,
	http = true,
	openssl_bin = true,
	disable_login = true,
	include_raw = true,
	cookies = true,
}

local function check_allowed_config(config)
	for k in pairs(config or {}) do
		if not CONFIG_FIELDS[k] then return nil, 'unsupported rtl8380m_http config field: ' .. tostring(k) end
	end
	return true, nil
end

local function configured_http_ref(http_config, opts)
	if type(opts.http_client_for) ~= 'function' then return nil, 'http_client_for dependency is required' end
	local ref, err = opts.http_client_for(http_config.capability)
	if not ref then return nil, err end
	return ref, nil
end

function M.new(config, opts)
	config = config or {}
	opts = opts or {}
	local allowed, allowed_err = check_allowed_config(config)
	if not allowed then return nil, allowed_err end
	if type(opts.provider_id) ~= 'string' or opts.provider_id == '' then return nil, 'opts.provider_id is required' end
	local base_url, base_url_err = ensure_base_url(config.base_url)
	if not base_url then return nil, base_url_err end
	local username = getenv_ref(config.username)
	local password = getenv_ref(config.password)
	if type(username) ~= 'string' or username == '' then return nil, 'username is required' end
	if type(password) ~= 'string' or password == '' then return nil, 'password is required' end
	local http_config, http_config_err = require_http_config(config)
	if not http_config then return nil, http_config_err end
	local http_ref, http_ref_err = configured_http_ref(http_config, opts)
	if not http_ref then return nil, http_ref_err end
	local timeout_s = tonumber(config.timeout_s)
	if not timeout_s or timeout_s <= 0 then return nil, 'timeout_s must be a positive number' end
	return setmetatable({
		id = opts.provider_id,
		base_url = base_url,
		mode = config.mode or 'read_only',
		username = username,
		password = password,
		timeout_s = timeout_s,
		response_parser = http_config.response_parser,
		max_response_bytes = http_config.max_response_bytes,
		http_ref = http_ref,
		openssl_bin = config.openssl_bin or os.getenv('SWITCH_OPENSSL') or 'openssl',
		disable_login = config.disable_login == true,
		include_raw = config.include_raw == true,
		logger = opts.logger,
		jar = CookieJar.new(config.cookies or { cookie_language = 'defLang_en' }),
		logged_in = false,
	}, Provider), nil
end

function Provider:fetch_snapshot()
	if self.client and type(self.client.snapshot) == 'function' then
		local data, err = self.client:snapshot(self)
		if not data then return { ok = false, provider_id = self.id, status = { state = 'unavailable', available = false, driver = DRIVER, err = err } } end
		return build_snapshot(self, data)
	end

	local ok_login, lerr = login(self)
	if not ok_login then
		return { ok = false, provider_id = self.id, status = { state = 'unavailable', available = false, driver = DRIVER, err = lerr or 'login failed' } }
	end

	local data = {}
	for _, cmd in ipairs(READ_COMMANDS) do
		local d, err = get_cmd(self, cmd)
		if not d then
			return { ok = false, provider_id = self.id, status = { state = 'unavailable', available = false, driver = DRIVER, err = err or ('failed to read ' .. cmd) } }
		end
		data[cmd] = d
	end
	return build_snapshot(self, data)
end

function Provider:fetch_snapshot_op(_req)
	return op.guard(function ()
		return fibers.run_scope_op(function ()
			return self:fetch_snapshot()
		end):wrap(function (status, _report, result_or_primary, err)
			if status == 'ok' then return result_or_primary, err end
			return {
				ok = false,
				provider_id = self.id,
				status = {
					state = 'unavailable',
					available = false,
					driver = DRIVER,
					err = tostring(result_or_primary or status or 'snapshot failed'),
				},
			}, nil
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
	VLAN_MODE = VLAN_MODE,
	VLAN_ACCEPT_FRAME = VLAN_ACCEPT_FRAME,
	VLAN_MEMBERSHIP = VLAN_MEMBERSHIP,
	parse_vlan_membership_string = parse_vlan_membership_string,
	build_snapshot = function(provider_like, data) return build_snapshot(provider_like or { id = 'switch-main', mode = 'read_only' }, data or {}) end,
	build_surfaces = build_surfaces,
	parse_runtime = parse_runtime,
	parse_power = parse_power,
	parse_surface_counters = parse_surface_counters,
}

return M
