local file = require 'fibers.io.file'
local op   = require 'fibers.op'
local safe = require 'coxpcall'

local M = {}

local function endpoint(rd, wr)
	local ep = {
		_rd = rd,
		_wr = wr,
		_closed = false,
	}

	function ep:read_line_op(opts)
		if self._closed then
			return op.always(nil, 'closed')
		end
		return self._rd:read_line_op(opts)
	end

	function ep:write_op(...)
		if self._closed then
			return op.always(nil, 'closed')
		end
		return self._wr:write_op(...)
	end

	function ep:close_op()
		if not self._closed then
			self._closed = true
			safe.pcall(function() self._wr:close() end)
			safe.pcall(function() self._rd:close() end)
		end
		return op.always(true, nil)
	end

	function ep:setvbuf(mode, size)
		pcall(function() self._rd:setvbuf(mode, size) end)
		pcall(function() self._wr:setvbuf(mode, size) end)
		return self
	end

	return ep
end

function M.new_pair()
	local a_rd, a_wr = file.pipe()
	local b_rd, b_wr = file.pipe()

	return endpoint(b_rd, a_wr), endpoint(a_rd, b_wr)
end

return M
