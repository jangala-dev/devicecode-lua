local contracts = require 'devicecode.support.contracts'

local tests = {}
local function assert_true(v, msg) if v ~= true then error(msg or 'expected true', 2) end end
local function assert_raises(fn)
	local ok = pcall(fn)
	if ok then error('expected error', 2) end
end

function tests.test_mailbox_contracts_are_shape_based()
	local rx = { recv_op = function () end }
	local tx = { send_op = function () end }
	assert_true(contracts.is_mailbox_rx(rx))
	assert_true(contracts.is_mailbox_tx(tx))
	contracts.require_rx(rx, 'rx')
	contracts.require_tx(tx, 'tx')
	assert_raises(function () contracts.require_rx({}, 'rx') end)
end

function tests.test_resource_contracts()
	contracts.require_terminate({ terminate = function () end }, 'res')
	assert_raises(function () contracts.require_terminate({}, 'res') end)
end

return tests
