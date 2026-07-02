-- tests/integration/devhost/local_ui_http_spec.lua
--
-- Devhost coverage for the initial local UI port.  These tests deliberately go
-- through curl and the real HTTP/UI/GSM services.  Only the HAL control-store is
-- faked so that APN persistence can be exercised without hardware.

local cjson = require 'cjson.safe'

local runfibers = require 'tests.support.run_fibers'
local harness = require 'tests.support.local_ui_devhost'

local T = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg)
	if a ~= b then fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end
end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end return v end
local function assert_nil(v, msg) if v ~= nil then fail((msg or 'expected nil') .. ': got ' .. tostring(v)) end end

local function devhost_port(offset)
	local base = tonumber(os.getenv('LOCAL_UI_DEVHOST_PORT')) or 18120
	return base + (offset or 0)
end

local function json_body(status, body)
	assert_eq(status, '200', body)
	local decoded, err = cjson.decode(body or '')
	return assert_not_nil(decoded, 'expected JSON body, got: ' .. tostring(body) .. ' decode_err=' .. tostring(err))
end

function T.devhost_local_ui_serves_static_and_curated_bootstrap_over_real_http()
	runfibers.run(function (scope)
		local inst = harness.start(scope, { port = devhost_port(1), static_root = 'src/services/ui/www' })
		harness.wait_http_ready(inst.base_url, { timeout = 5 })

		local status, body = harness.curl({
			'--silent', '--show-error', '--max-time', '5',
			'--write-out', '\n__HTTP_STATUS__:%{http_code}',
			inst.base_url .. '/',
		})
		assert_eq(status, '200')
		assert_true(body:find('Jangala Status Page', 1, true) ~= nil, 'static UI should serve the app shell')
		assert_true(body:find('/assets/index-', 1, true) ~= nil, 'static UI should reference the generated app bundle')

		status, body = harness.curl({
			'--silent', '--show-error', '--max-time', '5',
			'--write-out', '\n__HTTP_STATUS__:%{http_code}',
			inst.base_url .. '/overview',
		})
		assert_eq(status, '200')
		assert_true(body:find('Jangala Status Page', 1, true) ~= nil,
			'SPA fallback should serve index.html for browser routes')

		status, body = harness.curl({
			'--silent', '--show-error', '--max-time', '5',
			'--write-out', '\n__HTTP_STATUS__:%{http_code}',
			inst.base_url .. '/api/local-ui/bootstrap',
		})
		local payload = json_body(status, body)
		assert_eq(payload.schema, 'devicecode.ui.local-bootstrap/1')
		assert_not_nil(payload.items['state/net/summary'], 'bootstrap should include curated network state')
		assert_not_nil(payload.items['state/device/components'], 'bootstrap should include curated device state')
		assert_nil(payload.items['raw/host/secret'], 'bootstrap must not include raw HAL topics')
		assert_nil(payload.items['cfg/secret'], 'bootstrap must not include cfg topics')
	end, { timeout = 12 })
end

function T.devhost_local_ui_apns_round_trip_through_gsm_and_fake_control_store()
	runfibers.run(function (scope)
		local inst = harness.start(scope, { port = devhost_port(2), static_root = 'src/services/ui/www' })
		harness.wait_http_ready(inst.base_url, { timeout = 5 })

		local apns = {
			records = {
				{
					carrier = 'Demo Carrier',
					mcc = '234',
					mnc = '10',
					apn = 'demo.internet',
					user = 'clinic',
					password = 'prototype-secret',
				},
			},
		}

		local status, body = harness.curl_json('PUT', inst.base_url .. '/api/gsm/apns/custom', apns)
		assert_eq(status, '200')
		assert_true(body.ok, 'APN PUT should succeed')
		assert_eq(body.apns[1].apn, 'demo.internet')

		status, body = harness.curl_json('GET', inst.base_url .. '/api/gsm/apns/custom')
		assert_eq(status, '200')
		assert_eq(body[1].carrier, 'Demo Carrier')
		assert_eq(body[1].password, 'prototype-secret')

		local stored = assert_not_nil(inst.control_store:get('custom-apns-v1'),
			'APN list should be persisted in fake control-store')
		assert_true(stored:find('demo.internet', 1, true) ~= nil, 'persisted APN JSON should contain the APN')

		status, body = harness.curl_json('GET', inst.base_url .. '/api/local-ui/bootstrap')
		assert_eq(status, '200')
		local apn_state = assert_not_nil(body.items['state/gsm/apns/custom'],
			'bootstrap should include GSM APN retained state after PUT')
		assert_eq(apn_state.payload.count, 1)
		assert_eq(apn_state.payload.records[1].apn, 'demo.internet')
		assert_eq(apn_state.payload.records[1].password, nil)
		assert_eq(apn_state.payload.records[1].user, nil)
		assert_eq(apn_state.payload.records[1].has_password, true)
		assert_eq(apn_state.payload.records[1].has_user, true)

		local saw_put = false
		for _, call in ipairs(inst.control_store.calls) do
			if call.method == 'put' and call.payload and call.payload.key == 'custom-apns-v1' then saw_put = true end
		end
		assert_true(saw_put, 'UI APN PUT should have reached GSM and then the control-store capability')
	end, { timeout = 12 })
end

function T.devhost_local_ui_diagnostics_route_is_stubbed_for_now()
	runfibers.run(function (scope)
		local inst = harness.start(scope, { port = devhost_port(3), static_root = 'src/services/ui/www' })
		harness.wait_http_ready(inst.base_url, { timeout = 5 })

		local status, body = harness.curl_json('GET', inst.base_url .. '/api/diagnostics')
		assert_eq(status, '200')
		assert_eq(body.schema, 'devicecode.diagnostics.stub/1')
		assert_true(body.stub, 'diagnostics should remain explicitly stubbed in this pass')
		assert_not_nil(body.diagnostics, 'stub should preserve old diagnostics body shape')
		assert_not_nil(body.diagnostics_logs, 'stub should preserve old diagnostics logs shape')
	end, { timeout = 12 })
end

return T
