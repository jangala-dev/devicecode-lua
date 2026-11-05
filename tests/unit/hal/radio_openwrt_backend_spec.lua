-- tests/unit/hal/radio_openwrt_backend_spec.lua
--
-- OpenWrt radio backend command handling, with `fibers.io.exec` stubbed.

local op = require 'fibers.op'
local runfibers = require 'tests.support.run_fibers'

local T = {}

local IMPL = 'services.hal.backends.radio.providers.openwrt.impl'

-- Load the backend with exec.command returning the given results in turn:
-- { out, status, code }.
local function load_with_exec(results)
	local real_exec = package.loaded['fibers.io.exec']
	local calls = {}
	package.loaded['fibers.io.exec'] = {
		command = function (spec)
			calls[#calls + 1] = spec
			local r = table.remove(results, 1)
			return { output_op = function () return op.always(r[1], r[2], r[3], nil, nil) end }
		end,
	}
	package.loaded[IMPL] = nil
	local impl = require(IMPL)
	package.loaded['fibers.io.exec'] = real_exec
	package.loaded[IMPL] = nil
	return impl, calls
end

function T.station_dump_failure_is_an_error_not_an_empty_list()
	runfibers.run(function ()
		local impl = load_with_exec({
			{ 'Station aa:bb:cc:dd:ee:ff (on radio0_i0)\n', 'exited', 0 },
			{ 'command failed: No such device (-19)\n', 'exited', 237 },
		})
		local backend = impl.new('radio0')

		local macs, err = backend:get_connected_macs('radio0_i0')
		assert(err == '', 'successful dump: ' .. tostring(err))
		assert(#macs == 1 and macs[1] == 'aa:bb:cc:dd:ee:ff', 'one station parsed')

		macs, err = backend:get_connected_macs('radio0_i0')
		assert(err ~= '' and err:find('No such device', 1, true), 'failed dump reports an error: ' .. tostring(err))
		assert(#macs == 0)
	end, { timeout = 1 })
end

function T.dhcp_hostnames_are_read_from_lease_lines()
	runfibers.run(function ()
		local impl = load_with_exec({
			{ '1700000000 AA:BB:CC:DD:EE:FF 172.28.32.10 laptop 01:aa:bb:cc:dd:ee:ff\n'
				.. '1700000000 11:22:33:44:55:66 172.28.32.11 * *\n', 'exited', 0 },
		})
		local names, err = impl.new('radio0'):get_dhcp_hostnames()
		assert(err == '', tostring(err))
		assert(names['aa:bb:cc:dd:ee:ff'] == 'laptop', 'hostname keyed by lowercase mac')
		assert(names['11:22:33:44:55:66'] == nil, 'lease without a hostname skipped')
	end, { timeout = 1 })
end

return T
