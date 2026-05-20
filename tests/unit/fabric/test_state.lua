-- tests/unit/fabric/test_state.lua

local fibers = require 'fibers'
local busmod = require 'bus'

local state = require 'services.fabric.state'
local topics = require 'services.fabric.topics'
local probe = require 'tests.support.bus_probe'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil value') end end

function tests.test_projector_retains_transfer_view_with_correlation()
	fibers.run(function (scope)
		local bus = busmod.new()
		local conn = bus:connect()
		local tx, rx = state.new_queue(8)
		assert_true(scope:spawn(function ()
			return state.run_projector(scope, { conn = conn, state_rx = rx })
		end))

		assert_true(tx:send(state.component_snapshot_event('link-a', 1, 'transfer', {
			manager_id = 'link-a:transfer',
			last = {
				request_id = 'req-1',
				request_generation = 1,
				direction = 'send',
				status = 'ok',
				result = {
					xfer_id = 'xfer-1',
					request_id = 'req-1',
					target = 'updater/main',
					job_id = 'job-1',
					component = 'mcu',
					digest_alg = 'xxhash32',
					digest = '12345678',
					size = 5,
					sent_bytes = 5,
					retransmits = 1,
				},
			},
		})))

		local payload = probe.wait_retained_payload(conn, topics.state_transfer('xfer-1'), { timeout = 0.3 })
		assert_eq(payload.kind, 'fabric.transfer')
		assert_eq(payload.link_id, 'link-a')
		assert_eq(payload.xfer_id, 'xfer-1')
		assert_eq(payload.state, 'ok')
		assert_eq(payload.sent_bytes, 5)
		assert_eq(payload.retransmits, 1)
		assert_eq(payload.correlation.job_id, 'job-1')
		assert_eq(payload.correlation.component, 'mcu')

		tx:close('done')
	end)
end

return tests
