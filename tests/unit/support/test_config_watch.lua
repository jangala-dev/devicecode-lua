local config_watch = require 'devicecode.support.config_watch'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

function M.test_extracts_data_from_retained_config_record()
	local rec = { rev = 12, data = { enabled = true } }
	eq(config_watch._test.data_of(rec), rec.data)
	eq(config_watch._test.rev_of(rec, 0), 12)
end

function M.test_plain_payload_is_supported_for_bootstrap_and_unit_tests()
	local raw = { schema = 'x' }
	eq(config_watch._test.data_of(raw), raw)
	eq(config_watch._test.rev_of(raw, 7), 7)
end

function M.test_standard_cfg_topic_shape()
	local topic = config_watch.topic('ui')
	eq(topic[1], 'cfg')
	eq(topic[2], 'ui')
end

return M
