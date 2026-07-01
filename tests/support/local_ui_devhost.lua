-- tests/support/local_ui_devhost.lua
--
-- Shared devhost harness for the initial local UI port.  It composes the real
-- HTTP, UI and GSM services over an in-process bus, with a fake HAL
-- control-store capability for durable APN tests and demos.

local busmod = require 'bus'
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local exec   = require 'fibers.io.exec'
local cjson  = require 'cjson.safe'
local safe   = require 'coxpcall'

local http_service = require 'services.http.service'
local ui_service   = require 'services.ui.service'
local gsm_service  = require 'services.gsm'
local fake_control_store_mod = require 'tests.support.fake_control_store'
local probe = require 'tests.support.bus_probe'

local M = {}

local function assert_spawn(scope, fn, label)
	local ok, err = scope:spawn(fn)
	if ok ~= true then error((label or 'spawn failed') .. ': ' .. tostring(err), 0) end
	return true
end

local function topic_key(parts)
	local out = {}
	for i = 1, #(parts or {}) do out[#out + 1] = tostring(parts[i]) end
	return table.concat(out, '/')
end

local function dirname(path)
	path = tostring(path or ''):gsub('\\', '/')
	return path:match('^(.*)/[^/]*$') or '.'
end

local function join_path(a, b)
	b = tostring(b or ''):gsub('\\', '/')
	if b:sub(1, 1) == '/' then return b end
	a = tostring(a or ''):gsub('\\', '/')
	if a == '' or a == '.' then return b end
	return a .. '/' .. b
end

local function normalise_path(path)
	path = tostring(path or ''):gsub('\\', '/')
	local absolute = path:sub(1, 1) == '/'
	local parts = {}
	for part in path:gmatch('[^/]+') do
		if part == '' or part == '.' then
			-- skip
		elseif part == '..' then
			if #parts > 0 and parts[#parts] ~= '..' then
				parts[#parts] = nil
			elseif not absolute then
				parts[#parts + 1] = '..'
			end
		else
			parts[#parts + 1] = part
		end
	end
	local out = table.concat(parts, '/')
	if absolute then return '/' .. out end
	return out ~= '' and out or '.'
end

local function file_exists(path)
	local f = io.open(path, 'r')
	if f then f:close(); return true end
	return false
end

local function repo_root_from_source()
	local source = debug.getinfo(1, 'S').source or ''
	source = source:gsub('^@', ''):gsub('\\', '/')
	return normalise_path(join_path(dirname(source), '../..'))
end

local REPO_ROOT = repo_root_from_source()

function M.resolve_static_root(root)
	root = tostring(root or 'src/services/ui/www')
	if root:sub(1, 1) == '/' then return root end
	local candidates = {
		root,
		join_path(REPO_ROOT, root),
		join_path(REPO_ROOT, 'tests/' .. root),
		join_path(REPO_ROOT, 'src/services/ui/www'),
	}
	for _, candidate in ipairs(candidates) do
		candidate = normalise_path(candidate)
		if file_exists(candidate .. '/index.html') then return candidate end
	end
	return root
end

function M.ui_cfg(port, root)
	return {
		schema = 'devicecode.config/ui/1',
		enabled = true,
		http = {
			enabled = true,
			cap_id = 'main',
			host = '127.0.0.1',
			port = port,
			max_active_requests = 8,
		},
		static = {
			root = root or 'src/services/ui/www',
			index = 'index.html',
			chunk_size = 16384,
		},
		sse = { enabled = true, replay = true, queue_len = 16 },
		sessions = { prune_interval = false },
		updates = {
			upload = {
				enabled = false,
				max_bytes = 0,
				require_auth = false,
				component = 'mcu',
				create_job = false,
				start_job = false,
			},
			commit = { require_auth = false },
		},
	}
end

function M.gsm_cfg(store_id)
	return {
		schema = 'devicecode.config/gsm/1',
		apn_store = {
			kind = 'control-store',
			id = store_id or 'gsm',
			key = 'custom-apns-v1',
		},
		modems = {
			default = { enabled = false, signal_freq = 60 },
			known = {},
		},
	}
end

local function retain_config(conn, service, data, rev)
	conn:retain({ 'cfg', service }, {
		schema = 'devicecode.config.snapshot/1',
		service = service,
		rev = rev or 1,
		data = data,
	})
end

function M.publish_demo_state(conn)
	conn:retain({ 'state', 'device', 'identity' }, {
		schema = 'devicecode.device.identity/1',
		serial = 'BBX-DEMO-0001',
		model = 'Big Box devhost',
	})
	conn:retain({ 'state', 'device', 'components' }, {
		cm5 = { id = 'cm5', label = 'CM5', state = 'running' },
		mcu = { id = 'mcu', label = 'MCU', state = 'running' },
	})
	conn:retain({ 'state', 'net', 'summary' }, {
		schema = 'devicecode.net.summary/1',
		state = 'running',
		wan = 'cellular',
	})
	conn:retain({ 'state', 'net', 'wan_runtime' }, {
		schema = 'devicecode.net.wan-runtime/1',
		selected = 'gsm-main',
		internet = true,
	})
	conn:retain({ 'state', 'fabric', 'summary' }, {
		schema = 'devicecode.fabric.summary/1',
		state = 'running',
		links = 0,
	})
	conn:retain({ 'raw', 'host', 'secret' }, { should_not = 'be in local-ui bootstrap' })
	conn:retain({ 'cfg', 'secret' }, { should_not = 'be in local-ui bootstrap' })
end

function M.start(scope, opts)
	opts = opts or {}
	local port = opts.port or tonumber(os.getenv('LOCAL_UI_DEVHOST_PORT')) or 18089
	local static_root = M.resolve_static_root(opts.static_root or 'src/services/ui/www')
	local bus = opts.bus or busmod.new()
	local control_store = opts.control_store or fake_control_store_mod.new({ id = opts.store_id or 'gsm' })

	local config_conn = bus:connect({ origin_base = { kind = 'test', service = 'config' } })
	control_store:start(bus:connect({ origin_base = { kind = 'test', service = 'fake-hal-control-store' } }), {
		id = opts.store_id or 'gsm',
		scope = scope,
	})
	retain_config(config_conn, 'gsm', M.gsm_cfg(opts.store_id or 'gsm'), 1)
	retain_config(config_conn, 'ui', M.ui_cfg(port, static_root), 1)
	if opts.demo_state ~= false then M.publish_demo_state(config_conn) end

	assert_spawn(scope, function (service_scope)
		http_service.run(service_scope, {
			conn = bus:connect({ origin_base = { service = 'http' } }),
			id = 'main',
			backend_timeout = 2,
			connection_setup_timeout = 2,
			intra_stream_timeout = 2,
			max_accept_queue = 32,
		})
	end, 'http service')

	assert_spawn(scope, function ()
		gsm_service.start(bus:connect({ origin_base = { service = 'gsm' } }), {
			name = 'gsm',
			env = 'dev',
			heartbeat_s = 60,
		})
	end, 'gsm service')

	assert_spawn(scope, function (service_scope)
		ui_service.run(service_scope, {
			conn = bus:connect({ origin_base = { service = 'ui' } }),
			bus = bus,
			connect = function () return bus:connect({ origin_base = { service = 'ui-request' } }) end,
			service_id = 'ui',
			config = M.ui_cfg(port, static_root),
			read_model_opts = { queue_len = 128 },
			http_call_opts = { timeout = 3 },
			command_timeout = 3,
			apn_timeout = 3,
			encode_json = function (value)
				local encoded, err = cjson.encode(value)
				if type(encoded) ~= 'string' then error(err or 'json_encode_failed', 0) end
				return encoded
			end,
		})
	end, 'ui service')

	local probe_conn = bus:connect({ origin_base = { kind = 'test', service = 'probe' } })
	probe.wait_retained_payload(probe_conn, { 'cap', 'http', 'main', 'status' }, { timeout = 2 })
	probe.wait_retained_payload(probe_conn, { 'cap', 'gsm', 'main', 'status' }, { timeout = 2 })

	return {
		bus = bus,
		port = port,
		base_url = ('http://127.0.0.1:%d'):format(port),
		control_store = control_store,
		config_conn = config_conn,
	}
end

local function parse_curl_output(out)
	out = tostring(out or '')
	local status = out:match('\n__HTTP_STATUS__:(%d+)%s*$')
	local body = out:gsub('\n__HTTP_STATUS__:%d+%s*$', '')
	return status, body
end

function M.curl(args)
	local cmd = exec.command('curl', unpack(args))
	local out, st, code, sig, err = fibers.perform(cmd:combined_output_op())
	if not (st == 'exited' and code == 0) then
		error(('curl failed: status=%s code=%s signal=%s err=%s output=%s'):format(
			tostring(st), tostring(code), tostring(sig), tostring(err), tostring(out)
		), 0)
	end
	return parse_curl_output(out)
end

function M.curl_json(method, url, payload)
	local args = {
		'--silent', '--show-error', '--max-time', '5',
		'--write-out', '\n__HTTP_STATUS__:%{http_code}',
		'--request', method,
	}
	if payload ~= nil then
		args[#args + 1] = '--header'
		args[#args + 1] = 'Content-Type: application/json'
		args[#args + 1] = '--data-binary'
		args[#args + 1] = assert(cjson.encode(payload))
	end
	args[#args + 1] = url
	local status, body = M.curl(args)
	local decoded = nil
	if body ~= '' then
		local err
		decoded, err = cjson.decode(body)
		if decoded == nil then
			error(('expected JSON response from %s %s, got status=%s body=%q decode_err=%s'):format(
				tostring(method), tostring(url), tostring(status), tostring(body), tostring(err)
			), 2)
		end
	end
	return status, decoded, body
end

function M.wait_http_ready(base_url, opts)
	opts = opts or {}
	local ok = probe.wait_until(function ()
		local success, ready = safe.pcall(function ()
			local st = M.curl({ '--silent', '--show-error', '--max-time', '2', '--output', '/dev/null', '--write-out', '\n__HTTP_STATUS__:%{http_code}', base_url .. '/api/local-ui/bootstrap' })
			return st == '200'
		end)
		return success == true and ready == true
	end, { timeout = opts.timeout or 4, interval = 0.05 })
	if not ok then error('local UI HTTP endpoint did not become ready: ' .. tostring(base_url), 0) end
	return true
end

function M.topic_key(parts) return topic_key(parts) end

return M
