local runfibers = require 'tests.support.run_fibers'
local cap_args  = require 'services.hal.types.capability_args'

local T = {}

local function mk_tmpdir(tag)
	local path = ('/tmp/dc-lua-%s-%d-%06d'):format(tag, os.time(), math.random(0, 999999))
	local ok = os.execute(('mkdir -p %q'):format(path))
	assert(ok == true or ok == 0, 'failed to create temp dir: ' .. path)
	return path
end

local function rm_rf(path)
	os.execute(('rm -rf %q'):format(path))
end

local function read_file(path)
	local f, err = io.open(path, 'rb')
	if not f then return nil, err end
	local data = f:read('*a')
	f:close()
	return data
end

local function fresh_provider(root)
	package.loaded['services.hal.drivers.control_store_provider'] = nil
	return require('services.hal.drivers.control_store_provider').new(root, nil)
end

function T.status_op_reports_root_and_kind()
	local root = mk_tmpdir('csp-status')
	local provider = fresh_provider(root)

	runfibers.run(function()
		local ok, payload = require('fibers').perform(provider:status_op())
		assert(ok == true)
		assert(type(payload) == 'table')
		assert(payload.root == root)
		assert(payload.kind == 'control-store')
	end)

	rm_rf(root)
end

function T.put_get_and_list_round_trip()
	local root = mk_tmpdir('csp-roundtrip')
	local provider = fresh_provider(root)

	runfibers.run(function()
		local fibers = require 'fibers'

		local put_opts = assert(cap_args.new.ControlStorePutOpts('alpha', 'hello'))
		local ok_put, err_put = fibers.perform(provider:put_op(put_opts))
		assert(ok_put == true, tostring(err_put))

		local get_opts = assert(cap_args.new.ControlStoreGetOpts('alpha'))
		local ok_get, value = fibers.perform(provider:get_op(get_opts))
		assert(ok_get == true, tostring(value))
		assert(value == 'hello')

		local ok_list, keys = fibers.perform(provider:list_op())
		assert(ok_list == true, tostring(keys))
		assert(#keys == 1)
		assert(keys[1] == 'alpha')
	end)

	rm_rf(root)
end

function T.list_op_filters_by_prefix_and_is_sorted_unique()
	local root = mk_tmpdir('csp-prefix')
	local provider = fresh_provider(root)

	runfibers.run(function()
		local fibers = require 'fibers'

		for _, pair in ipairs({
			{ 'a.one', '1' },
			{ 'a.two', '2' },
			{ 'b.one', '3' },
		}) do
			local ok, err = fibers.perform(provider:put_op(assert(cap_args.new.ControlStorePutOpts(pair[1], pair[2]))))
			assert(ok == true, tostring(err))
		end

		local ok, keys = fibers.perform(provider:list_op(assert(cap_args.new.ControlStoreListOpts('a.'))))
		assert(ok == true, tostring(keys))
		assert(#keys == 2)
		assert(keys[1] == 'a.one')
		assert(keys[2] == 'a.two')
	end)

	rm_rf(root)
end

function T.get_op_rejects_invalid_key()
	local root = mk_tmpdir('csp-invalid-get')
	local provider = fresh_provider(root)

	runfibers.run(function()
		local fibers = require 'fibers'
		local ok, err = fibers.perform(provider:get_op({ key = '../bad' }))
		assert(ok == false)
		assert(tostring(err):match('invalid key'))
	end)

	rm_rf(root)
end

function T.put_op_rejects_invalid_data()
	local root = mk_tmpdir('csp-invalid-put')
	local provider = fresh_provider(root)

	runfibers.run(function()
		local fibers = require 'fibers'
		local ok, err = fibers.perform(provider:put_op({ key = 'alpha', data = 123 }))
		assert(ok == false)
		assert(tostring(err):match('data must be a string'))
	end)

	rm_rf(root)
end

function T.get_op_returns_not_found_for_missing_key()
	local root = mk_tmpdir('csp-missing')
	local provider = fresh_provider(root)

	runfibers.run(function()
		local fibers = require 'fibers'
		local ok, err = fibers.perform(provider:get_op(assert(cap_args.new.ControlStoreGetOpts('missing'))))
		assert(ok == false)
		assert(tostring(err):match('not found'))
	end)

	rm_rf(root)
end

function T.delete_op_removes_key_from_index_and_truncates_file()
	local root = mk_tmpdir('csp-delete')
	local provider = fresh_provider(root)
	local key_path = root .. '/alpha'
	local index_path = root .. '/.control_store_index'

	runfibers.run(function()
		local fibers = require 'fibers'

		local ok_put, err_put = fibers.perform(provider:put_op(assert(cap_args.new.ControlStorePutOpts('alpha', 'payload'))))
		assert(ok_put == true, tostring(err_put))

		local ok_del, err_del = fibers.perform(provider:delete_op(assert(cap_args.new.ControlStoreDeleteOpts('alpha'))))
		assert(ok_del == true, tostring(err_del))

		local ok_get, err_get = fibers.perform(provider:get_op(assert(cap_args.new.ControlStoreGetOpts('alpha'))))
		assert(ok_get == false)
		assert(tostring(err_get):match('not found'))

		local ok_list, keys = fibers.perform(provider:list_op())
		assert(ok_list == true, tostring(keys))
		assert(#keys == 0)
	end)

	local data = assert(read_file(key_path))
	assert(data == '', 'delete currently truncates underlying file')

	local index_data = assert(read_file(index_path))
	assert(index_data == '', 'index should no longer contain deleted key')

	rm_rf(root)
end

return T
