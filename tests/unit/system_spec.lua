-- tests/unit/system_spec.lua

local fibers = require 'fibers'
local op = require 'fibers.op'

local system = require 'services.system'

local T = {}

local function assert_true(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
end

local function assert_eq(a, b, msg)
	if a ~= b then
		error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
	end
end

function T.publish_platform_identity_metrics_reads_identity_rpc()
	fibers.run(function()
		local metrics = {}
		local svc = {
			obs_metric = function(_, key, payload)
				metrics[key] = payload
			end,
			obs_log = function() end,
		}
		local cap = {
			call_control_op = function(_, method, opts)
				assert_eq(method, 'get')
				assert_eq(opts.field, 'identity')
				return op.always({
					ok = true,
					reason = {
						hw_revision = 'bigbox-v1-cm-2',
						fw_version = 'bigbox-v1-cm-2-v0.11.0',
						serial = 'BB7YJWANBEA6GE',
						board_revision = '0xC04180',
					},
				})
			end,
		}

		assert_true(system._test.publish_platform_identity_metrics(svc, cap, 0.1))
		assert_eq(metrics.hw_id.value, 'bigbox-v1-cm-2')
		assert_eq(metrics.fw_id.value, 'bigbox-v1-cm-2-v0.11.0')
		assert_eq(metrics.serial.value, 'BB7YJWANBEA6GE')
		assert_eq(metrics.board_revision.value, '0xC04180')
		assert_eq(metrics.hw_id.namespace[1], 'system')
		assert_eq(metrics.hw_id.namespace[2], 'hw_id')
	end)
end

return T
