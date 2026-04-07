-- services/fabric/blob_source.lua
--
-- Blob source helpers for fabric transfer.
--
-- First pass:
--   * from_string(name, bytes[, opts])
--   * from_file(path[, opts])  -- reads the file eagerly into memory

local checksum = require 'services.fabric.checksum'
local file     = require 'fibers.io.file'

local M = {}

local function new_reader(bytes)
	local pos = 1
	local n = #bytes

	return {
		read = function(_, max_n)
			if pos > n then
				return nil, nil
			end
			max_n = math.max(1, math.floor(tonumber(max_n) or n))
			local chunk = bytes:sub(pos, math.min(n, pos + max_n - 1))
			pos = pos + #chunk
			return chunk, nil
		end,

		close = function()
			return true, nil
		end,
	}
end

local function make_string_source(name, bytes, opts)
	opts = opts or {}

	local sha256 = checksum.sha256_hex(bytes)
	local size = #bytes

	local src = {
		_name   = tostring(name or 'blob'),
		_bytes  = bytes,
		_size   = size,
		_sha256 = sha256,
		_meta   = opts.meta,
		_format = opts.format,
	}

	function src:name()
		return self._name
	end

	function src:size()
		return self._size
	end

	function src:sha256hex()
		return self._sha256
	end

	function src:format()
		return self._format
	end

	function src:meta()
		return self._meta
	end

	function src:open()
		return new_reader(self._bytes)
	end

	return src
end

function M.from_string(name, bytes, opts)
	if type(bytes) ~= 'string' then
		error('blob_source.from_string: bytes must be a string', 2)
	end
	return make_string_source(name, bytes, opts)
end

function M.from_file(path, opts)
	opts = opts or {}

	if type(path) ~= 'string' or path == '' then
		error('blob_source.from_file: path must be a non-empty string', 2)
	end

	local s, err = file.open(path, 'r')
	if not s then
		return nil, tostring(err)
	end

	local bytes, rerr = s:read_all()
	s:close()

	if rerr ~= nil then
		return nil, tostring(rerr)
	end

	local name = opts.name or path:match('([^/]+)$') or path
	return make_string_source(name, bytes or '', opts), nil
end

function M.is_blob_source(x)
	return type(x) == 'table'
		and type(x.open) == 'function'
		and type(x.size) == 'function'
		and type(x.sha256hex) == 'function'
end

return M
