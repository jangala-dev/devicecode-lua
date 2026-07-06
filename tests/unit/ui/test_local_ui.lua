-- tests/unit/ui/test_local_ui.lua

local routes = require 'services.ui.http.routes'
local sse = require 'services.ui.http.sse'
local read_model = require 'services.ui.read_model'
local local_model = require 'services.ui.local_model'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function ok(v,msg) if not v then fail(msg or 'expected truthy') end end

local function ctx(method, path)
	return { method = method, path = path }
end

function tests.test_routes_decode_local_ui_and_apn_routes()
	eq(routes.decode(ctx('GET', '/api/local-ui/bootstrap')).kind, 'local_ui_bootstrap')
	eq(routes.decode(ctx('GET', '/api/gsm/apns/custom')).kind, 'gsm_apns_get')
	eq(routes.decode(ctx('PUT', '/api/gsm/apns/custom')).kind, 'gsm_apns_put')
	eq(routes.decode(ctx('GET', '/api/diagnostics')).kind, 'diagnostics_stub')
	local route = routes.decode(ctx('GET', '/events'))
	eq(route.kind, 'sse')
	eq(route.pattern, nil)
	eq(route.patterns, nil)
end

function tests.test_sse_defaults_use_local_ui_prefixes_without_root_hash()
	local defaults = sse.default_patterns()
	local seen = {}
	ok(#defaults > 0)
	for _, pattern in ipairs(defaults) do
		local key = table.concat(pattern, '/')
		if key == '#' then fail('local-ui SSE must not subscribe to root #') end
		seen[key] = true
	end
	ok(seen['state/device/#'], 'state/device stream missing')
	ok(seen['state/net/#'], 'state/net stream missing')
	ok(seen['obs/v1/system/metric/#'], 'system metrics stream missing')
	eq(seen['obs/v1/gsm/event/#'], nil, 'generic GSM events should not be watched by /events')
	eq(seen['obs/v1/+/event/log'], nil, 'logs should use the monitor log follow endpoint')
end

function tests.test_local_model_allow_list_excludes_cfg_and_raw()
	local model = read_model.new()
	model:set({ 'state', 'net', 'summary' }, { ok = true })
	model:set({ 'state', 'gsm', 'apns', 'custom' }, { records = {} })
	model:set({ 'obs', 'v1', 'system', 'metric', 'cpu_util' }, {
		namespace = { 'system', 'cpu_util' },
		value = 12.5,
	})
	model:set({ 'state', 'device', 'component', 'switch-main' }, {
		available = true,
		observed = { wired = { raw = { secret = true } } },
		raw = { secret = true },
	})
	model:set({ 'state', 'device', 'components' }, {
		counts = { total = 1 },
		components = { ['switch-main'] = { raw = { secret = true } } },
	})
	model:set({ 'cfg', 'gsm' }, { secret = true })
	model:set({ 'raw', 'member', 'mcu' }, { secret = true })
	local boot = local_model.bootstrap(model:snapshot())
	ok(boot.items['state/net/summary'])
	ok(boot.items['state/gsm/apns/custom'])
	ok(boot.items['obs/v1/system/metric/cpu_util'])
	ok(boot.items['state/device/component/switch-main'])
	eq(boot.items['state/device/component/switch-main'].payload.raw, nil)
	eq(boot.items['state/device/component/switch-main'].payload.observed, nil)
	ok(boot.items['state/device/components'])
	eq(boot.items['state/device/components'].payload.components, nil)
	if boot.items['cfg/gsm'] then fail('cfg/gsm leaked into local-ui bootstrap') end
	if boot.items['raw/member/mcu'] then fail('raw member leaked into local-ui bootstrap') end
end

function tests.test_local_model_keeps_logs_out_of_default_stream_and_bootstrap()
	local model = read_model.new()
	model:set({ 'obs', 'v1', 'net', 'event', 'log' }, {
		level = 'warn',
		message = 'not retained',
	})

	local log_event = local_model.project_event({
		op = 'set',
		topic = { 'obs', 'v1', 'net', 'event', 'log' },
		payload = {
			level = 'warn',
			message = 'not retained',
		},
	})
	ok(log_event, 'explicit canonical service log projection should remain supported')
	eq(log_event.payload.message, 'not retained')

	local ui_log = local_model.project_event({
		op = 'set',
		topic = { 'obs', 'v1', 'ui', 'event', 'log' },
		payload = { level = 'info', message = 'hidden' },
	})
	eq(ui_log, nil, 'ui service logs should remain denied')

	local gsm_log = local_model.project_event({
		op = 'set',
		topic = { 'obs', 'v1', 'gsm', 'event', 'log' },
		payload = { level = 'info', message = 'hidden' },
	})
	ok(gsm_log, 'explicit GSM service log projection should remain supported')

	local boot = local_model.bootstrap(model:snapshot())
	if boot.items['obs/v1/net/event/log'] then fail('log event leaked into local-ui bootstrap') end
end

return tests
