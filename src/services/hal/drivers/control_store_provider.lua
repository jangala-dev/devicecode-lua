---@module 'services.hal.drivers.control_store_provider'

local fibers = require 'fibers'
local op     = require 'fibers.op'
local file     = require 'fibers.io.file'
local resource = require 'devicecode.support.resource'

local M = {}

---@class ControlStoreProvider
---@field root string
---@field logger table|nil
local Provider = {}
Provider.__index = Provider

local INDEX_FILE = '.control_store_index'

local function valid_key(key)
	return type(key) == 'string'
		and key ~= ''
		and not key:find('[/\\]', 1)
		and key:match('^[%w%._%-]+$') ~= nil
end

local function path_for(root, key)
	return root .. '/' .. key
end

local function index_path(root)
	return root .. '/' .. INDEX_FILE
end

local function split_lines(s)
	local out = {}
	if s == '' then
		return out
	end
	for line in (s .. '\n'):gmatch('(.-)\n') do
		if line ~= '' then
			out[#out + 1] = line
		end
	end
	return out
end

local function join_lines(xs)
	return table.concat(xs, '\n')
end

local function sort_unique(xs)
	local seen, out = {}, {}
	for _, x in ipairs(xs) do
		if not seen[x] then
			seen[x] = true
			out[#out + 1] = x
		end
	end
	table.sort(out)
	return out
end

local function is_not_found_err(err)
	if err == nil then
		return false
	end
	local s = tostring(err):lower()
	return s:find('no such file', 1, true) ~= nil
		or s:find('not found', 1, true) ~= nil
		or s:find('enoent', 1, true) ~= nil
end

-- Box the currently synchronous file.open(...) impurity inside a single
-- operation-owned subtree. The caller still gets a proper Op.
local function with_open_file_op(path, mode, body_fn)
	return fibers.run_scope_op(function (scope)
		local f, err = file.open(path, mode)
		if not f then
			return false, tostring(err)
		end

		scope:finally(function (_, status, primary)
			resource.terminate_checked(f, primary or status or 'control store file closed', 'control store file cleanup failed')
		end)

		return body_fn(f)
	end):wrap(function (st, rep, ok, value_or_err)
		if st ~= 'ok' then
			return false, tostring(value_or_err or rep)
		end
		return ok, value_or_err
	end)
end

local function read_file_required_op(path)
	return with_open_file_op(path, 'r', function (f)
		local body, rerr = fibers.perform(f:read_all_op())
		if rerr ~= nil then
			return false, tostring(rerr)
		end
		return true, body or ''
	end)
end

local function read_index_op(root)
	local path = index_path(root)

	return fibers.run_scope_op(function ()
		local ok, body_or_err = fibers.perform(read_file_required_op(path))
		if ok then
			return true, sort_unique(split_lines(body_or_err))
		end

		if is_not_found_err(body_or_err) then
			return true, {}
		end

		return false, body_or_err
	end):wrap(function (st, rep, ok, value_or_err)
		if st ~= 'ok' then
			return false, tostring(value_or_err or rep)
		end
		return ok, value_or_err
	end)
end

local function write_file_op(path, data)
	return with_open_file_op(path, 'w', function (f)
		local n, werr = fibers.perform(f:write_op(data))
		if n == nil then
			return false, tostring(werr)
		end
		return true, nil
	end)
end

local function write_index_op(root, keys)
	return write_file_op(index_path(root), join_lines(sort_unique(keys)))
end

function Provider:status_op()
	return op.always(true, {
		root = self.root,
		kind = 'control-store',
	})
end

function Provider:get_op(opts)
	return op.guard(function ()
		if type(opts) ~= 'table' or not valid_key(opts.key) then
			return op.always(false, 'invalid key')
		end

		return fibers.run_scope_op(function ()
			local ok_index, keys_or_err = fibers.perform(read_index_op(self.root))
			if not ok_index then
				return false, keys_or_err
			end

			local present = false
			for _, k in ipairs(keys_or_err) do
				if k == opts.key then
					present = true
					break
				end
			end
			if not present then
				return false, 'not found'
			end

			return fibers.perform(read_file_required_op(path_for(self.root, opts.key)))
		end):wrap(function (st, rep, ok, value_or_err)
			if st ~= 'ok' then
				return false, tostring(value_or_err or rep)
			end
			return ok, value_or_err
		end)
	end)
end

function Provider:put_op(opts)
	return op.guard(function ()
		if type(opts) ~= 'table' or not valid_key(opts.key) then
			return op.always(false, 'invalid key')
		end
		if type(opts.data) ~= 'string' then
			return op.always(false, 'data must be a string')
		end

		return fibers.run_scope_op(function ()
			local okw, werr = fibers.perform(write_file_op(path_for(self.root, opts.key), opts.data))
			if not okw then
				return false, werr
			end

			local ok_index, keys_or_err = fibers.perform(read_index_op(self.root))
			if not ok_index then
				return false, keys_or_err
			end

			keys_or_err[#keys_or_err + 1] = opts.key
			return fibers.perform(write_index_op(self.root, keys_or_err))
		end):wrap(function (st, rep, ok, err)
			if st ~= 'ok' then
				return false, tostring(err or rep)
			end
			return ok, err
		end)
	end)
end

function Provider:delete_op(opts)
	return op.guard(function ()
		if type(opts) ~= 'table' or not valid_key(opts.key) then
			return op.always(false, 'invalid key')
		end

		return fibers.run_scope_op(function ()
			local ok_index, keys_or_err = fibers.perform(read_index_op(self.root))
			if not ok_index then
				return false, keys_or_err
			end

			local kept, present = {}, false
			for _, k in ipairs(keys_or_err) do
				if k == opts.key then
					present = true
				else
					kept[#kept + 1] = k
				end
			end
			if not present then
				return false, 'not found'
			end

			-- Temporary best-effort tombstone/truncate until the lower file layer
			-- gives us an unlink_op().
			local okw, werr = fibers.perform(write_file_op(path_for(self.root, opts.key), ''))
			if not okw then
				return false, werr
			end

			return fibers.perform(write_index_op(self.root, kept))
		end):wrap(function (st, rep, ok, err)
			if st ~= 'ok' then
				return false, tostring(err or rep)
			end
			return ok, err
		end)
	end)
end

function Provider:list_op(opts)
	return op.guard(function ()
		if opts ~= nil and type(opts) ~= 'table' then
			return op.always(false, 'invalid options')
		end

		local prefix = opts and opts.prefix or nil
		if prefix ~= nil and type(prefix) ~= 'string' then
			return op.always(false, 'invalid prefix')
		end

		return read_index_op(self.root):wrap(function (ok, keys_or_err)
			if not ok then
				return false, keys_or_err
			end

			if prefix == nil or prefix == '' then
				return true, keys_or_err
			end

			local out = {}
			for _, k in ipairs(keys_or_err) do
				if k:sub(1, #prefix) == prefix then
					out[#out + 1] = k
				end
			end
			return true, out
		end)
	end)
end

---@param root string
---@param logger table|nil
---@return ControlStoreProvider
function M.new(root, logger)
	assert(type(root) == 'string' and root ~= '', 'control_store_provider.new: invalid root')
	return setmetatable({
		root   = root,
		logger = logger,
	}, Provider)
end

M.Provider = Provider
return M
