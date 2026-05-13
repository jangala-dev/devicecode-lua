-- devicecode/support/contracts.lua
--
-- Application/runtime contracts for fibers, bus and finaliser-safe resources.

local validate = require 'shared.validate'

local M = {}

local function fail(name, msg, level)
	error((name or 'value') .. ' ' .. msg, (level or 1) + 1)
end

function M.is_op(v)
	return type(v) == 'table' and type(v.perform) == 'function'
end

function M.require_op(v, name, level)
	if not M.is_op(v) then fail(name, 'must be an Op', (level or 1) + 1) end
	return v
end

function M.is_mailbox_rx(v)
	return type(v) == 'table' and type(v.recv_op) == 'function'
end

function M.require_rx(v, name, level)
	if not M.is_mailbox_rx(v) then fail(name or 'rx', 'must provide recv_op()', (level or 1) + 1) end
	return v
end

function M.is_mailbox_tx(v)
	return type(v) == 'table' and type(v.send_op) == 'function'
end

function M.require_tx(v, name, level)
	if not M.is_mailbox_tx(v) then fail(name or 'tx', 'must provide send_op(value)', (level or 1) + 1) end
	return v
end

function M.has_terminate(v)
	return type(v) == 'table' and type(v.terminate) == 'function'
end

function M.require_terminate(v, name, level)
	if not M.has_terminate(v) then fail(name, 'must provide terminate(reason)', (level or 1) + 1) end
	return v
end

function M.has_close_op(v)
	return type(v) == 'table' and type(v.close_op) == 'function'
end

function M.require_close_op(v, name, level)
	if not M.has_close_op(v) then fail(name, 'must provide close_op()', (level or 1) + 1) end
	return v
end

function M.has_stream_contract(v)
	return type(v) == 'table'
		and type(v.read_some_op) == 'function'
		and type(v.write_all_op) == 'function'
		and (type(v.terminate) == 'function' or type(v.close_op) == 'function')
end

function M.require_stream_contract(v, name, level)
	if not M.has_stream_contract(v) then fail(name, 'must provide the stream contract', (level or 1) + 1) end
	return v
end

M.require_table = validate.table
M.require_function = validate.function_
M.require_positive_integer = validate.positive_integer
M.require_non_negative_integer = validate.non_negative_integer
M.require_positive_number = validate.positive_number

return M
