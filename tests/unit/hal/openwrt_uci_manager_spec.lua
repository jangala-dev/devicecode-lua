-- tests/unit/hal/openwrt_uci_manager_spec.lua

local fibers = require 'fibers'
local mailbox = require 'fibers.mailbox'
local queue = require 'devicecode.support.queue'

local uci_manager = require 'services.hal.backends.openwrt.uci_manager'
local probe = require 'tests.support.bus_probe'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function ok(v, msg) if not v then fail(msg) end return v end
local function eq(a, b, msg) if a ~= b then fail((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function contains(s, needle, msg) if type(s) ~= 'string' or not s:find(needle, 1, true) then fail(msg or ('expected ' .. tostring(s) .. ' to contain ' .. tostring(needle))) end end

local function fake_cursor(calls)
	return {
		set = function (_, ...)
			calls[#calls + 1] = { op = 'set', ... }
			return true
		end,
		delete = function (_, ...)
			calls[#calls + 1] = { op = 'delete', ... }
			return true
		end,
		commit = function (_, config)
			calls[#calls + 1] = { op = 'commit', config }
			return true
		end,
		revert = function (_, config)
			calls[#calls + 1] = { op = 'revert', config }
			return true
		end,
	}
end

function tests.test_commit_converts_values_and_runs_restart_commands()
	fibers.run(function (scope)
		local calls = {}
		local restarts = {}
		local mgr = ok(uci_manager.new({
			cursor = fake_cursor(calls),
			run_cmd = function (argv)
				restarts[#restarts + 1] = table.concat(argv, ' ')
				return true, nil
			end,
		}))
		ok(mgr:start(scope))

		local s = mgr:new_session()
		s:set('wireless', 'radio0', 'disabled', false)
		s:set('wireless', 'ssid0', 'network', { 'lan', 'guest' })
		s:delete('wireless', 'old_ssid')
		local ok_commit, err = fibers.perform(s:commit_op('wireless', {
			{ '/sbin/wifi', 'reload' },
			{ kind = 'restart', target = 'network' },
		}))
		ok(ok_commit, err)

		eq(calls[1].op, 'set')
		eq(calls[1][1], 'wireless')
		eq(calls[1][2], 'radio0')
		eq(calls[1][3], 'disabled')
		eq(calls[1][4], '0')
		eq(calls[2][4][1], 'lan')
		eq(calls[2][4][2], 'guest')
		eq(calls[3].op, 'delete')
		eq(calls[4].op, 'commit')
		eq(restarts[1], '/sbin/wifi reload')
		eq(restarts[2], '/etc/init.d/network restart')
	end)
end


function tests.test_start_accepts_already_started_owner_scope_from_caller_scope()
	fibers.run(function (scope)
		local owner = ok(scope:child())
		local hold_tx, hold_rx = mailbox.new(1)
		ok(owner:spawn(function () fibers.perform(hold_rx:recv_op()) end))

		local mgr = ok(uci_manager.new({
			cursor = fake_cursor({}),
			run_cmd = function () return true, nil end,
		}))

		local started, err = mgr:start(owner)
		ok(started, err)
		owner:cancel('test_done')
		hold_tx:close('test_done')
	end)
end

function tests.test_queue_full_is_reported_without_admission()
	fibers.run(function ()
		local mgr = ok(uci_manager.new({ queue_len = 0, cursor = fake_cursor({}) }))
		local ok_submit, err, admitted = fibers.perform(mgr:submit_op({
			config = 'network',
			changes = {
				{ op = 'set', config = 'network', section = 'lan', option = 'proto', value = 'static' },
			},
		}))
		eq(ok_submit, false)
		eq(admitted, false)
		contains(err, 'uci_manager_busy')
	end)
end

function tests.test_restart_commands_are_deduplicated_across_debounce_batch()
	fibers.run(function (scope)
		local calls = {}
		local restarts = {}
		local mgr = ok(uci_manager.new({
			cursor = fake_cursor(calls),
			debounce_s = 0.02,
			run_cmd = function (argv)
				restarts[#restarts + 1] = table.concat(argv, ' ')
				return true, nil
			end,
		}))
		ok(mgr:start(scope))

		local results = {}
		local r1 = {
			config = 'network',
			changes = { { op = 'set', config = 'network', section = 'lan', option = 'proto', value = 'static' } },
			restart_cmds = { { '/etc/init.d/network', 'reload' } },
		}
		local r2 = {
			config = 'network',
			changes = { { op = 'set', config = 'network', section = 'wan', option = 'proto', value = 'dhcp' } },
			restart_cmds = { { '/etc/init.d/network', 'reload' } },
		}

		scope:spawn(function () results[1] = { fibers.perform(mgr:submit_op(r1)) } end)
		scope:spawn(function () results[2] = { fibers.perform(mgr:submit_op(r2)) } end)

		ok(probe.wait_until(function () return results[1] and results[2] end, { timeout = 0.5 }), 'commit results expected')
		eq(results[1][1], true)
		eq(results[2][1], true)
		eq(#restarts, 1)
		eq(restarts[1], '/etc/init.d/network reload')
	end)
end


function tests.test_record_normalisation_does_not_mutate_caller_owned_record()
	local record = {
		config = 'network',
		changes = {
			{ op = 'set', config = 'network', section = 'lan', option = 'proto', value = 'static' },
		},
		restart_cmds = {
			{ kind = 'reload', target = 'network' },
		},
	}
	local original_restart = record.restart_cmds[1]
	local normalised, err = uci_manager._normalise_record_for_test(record)
	ok(normalised, err)
	eq(record.restart_cmds[1], original_restart, 'caller restart table should be untouched')
	eq(record.restart_cmds[1].kind, 'reload')
	eq(normalised.restart_cmds[1][1], '/etc/init.d/network')
	normalised.changes[1].value = 'dhcp'
	eq(record.changes[1].value, 'static', 'caller changes should be deep-copied')
end

function tests.test_add_alias_lists_rename_and_reorder_are_applied_in_order()
	fibers.run(function (scope)
		local calls = {}
		local cursor = fake_cursor(calls)
		cursor.add = function (_, config, stype)
			calls[#calls + 1] = { op = 'add', config, stype }
			return 'cfg123abc'
		end
		local get_count = 0
		cursor.get = function (_, config, section, option)
			calls[#calls + 1] = { op = 'get', config, section, option }
			get_count = get_count + 1
			if option == 'server' and get_count == 1 then return { '0.openwrt.pool.ntp.org' } end
			if option == 'server' then return { '0.openwrt.pool.ntp.org', '1.openwrt.pool.ntp.org' } end
			return nil
		end
		cursor.rename = function (_, ...)
			calls[#calls + 1] = { op = 'rename', ... }
			return true
		end
		cursor.reorder = function (_, ...)
			calls[#calls + 1] = { op = 'reorder', ... }
			return true
		end

		local mgr = ok(uci_manager.new({ cursor = cursor, run_cmd = function () return true end }))
		ok(mgr:start(scope))
		local s = mgr:new_session()
		local anon = s:add('system', 'timeserver')
		s:set('system', anon, 'enabled', true)
		s:add_list('system', anon, 'server', '1.openwrt.pool.ntp.org')
		s:del_list('system', anon, 'server', '0.openwrt.pool.ntp.org')
		s:rename('system', anon, 'ntp_runtime')
		s:reorder('system', 'ntp_runtime', 0)
		local ok_commit, err = fibers.perform(s:commit_op('system'))
		ok(ok_commit, err)

		eq(calls[1].op, 'add')
		eq(calls[1][1], 'system')
		eq(calls[1][2], 'timeserver')
		eq(calls[2].op, 'set')
		eq(calls[2][2], 'cfg123abc')
		eq(calls[2][4], '1')
		eq(calls[3].op, 'get')
		eq(calls[4].op, 'set')
		eq(calls[4][4][2], '1.openwrt.pool.ntp.org')
		eq(calls[5].op, 'get')
		eq(calls[6].op, 'set')
		eq(#calls[6][4], 1)
		eq(calls[6][4][1], '1.openwrt.pool.ntp.org')
		eq(calls[7].op, 'rename')
		eq(calls[7][2], 'cfg123abc')
		eq(calls[8].op, 'reorder')
		eq(calls[8][2], 'ntp_runtime')
		eq(calls[9].op, 'commit')
	end)
end

function tests.test_legacy_restart_shorthands_are_normalised()
	local record = {
		config = 'wireless',
		changes = {
			{ op = 'set', config = 'wireless', section = 'radio0', option = 'disabled', value = false },
		},
		restart_cmds = {
			{ 'wifi', 'reload' },
			{ 'service', 'dawn', 'restart' },
		},
	}
	local normalised, err = uci_manager._normalise_record_for_test(record)
	ok(normalised, err)
	eq(normalised.restart_cmds[1][1], '/sbin/wifi')
	eq(normalised.restart_cmds[1][2], 'reload')
	eq(normalised.restart_cmds[2][1], '/etc/init.d/dawn')
	eq(normalised.restart_cmds[2][2], 'restart')
end


function tests.test_transaction_rolls_back_touched_packages_on_partial_failure()
	fibers.run(function (scope)
		local calls = {}
		local snapshots = {
			network = {
				lan = { ['.type'] = 'interface', proto = 'static' },
			},
			dhcp = {
				dnsmasq = { ['.type'] = 'dnsmasq', domainneeded = '1' },
			},
		}
		local cursor = fake_cursor(calls)
		cursor.get_all = function (_, pkg)
			calls[#calls + 1] = { op = 'get_all', pkg }
			return snapshots[pkg] or {}
		end
		cursor.set = function (_, config, section, option, value)
			calls[#calls + 1] = { op = 'set', config, section, option, value }
			if config == 'dhcp' and section == 'bad' then return nil, 'synthetic failure' end
			return true
		end
		local mgr = ok(uci_manager.new({ cursor = cursor, run_cmd = function () return true end }))
		ok(mgr:start(scope))
		local result, admitted = fibers.perform(mgr:transaction_op({
			packages = { 'network', 'dhcp' },
			records = {
				{ config = 'network', changes = { { op = 'set', config = 'network', section = 'wan', option = 'interface' } } },
				{ config = 'dhcp', changes = { { op = 'set', config = 'dhcp', section = 'bad', option = 'dhcp' } } },
			},
		}))
		eq(admitted, true)
		eq(result.ok, false)
		eq(result.status, 'failed_rolled_back')
		eq(result.rollback.ok, true)
	end)
end


function tests.test_replace_package_deletes_existing_sections_before_writing_desired_state()
	fibers.run(function (scope)
		local calls = {}
		local cursor = fake_cursor(calls)
		cursor.get_all = function (_, pkg)
			calls[#calls + 1] = { op = 'get_all', pkg }
			return {
				old = { ['.type'] = 'interface', proto = 'dhcp' },
				lan = { ['.type'] = 'interface', proto = 'static', stale = 'yes' },
			}
		end
		local mgr = ok(uci_manager.new({ cursor = cursor, run_cmd = function () return true end }))
		ok(mgr:start(scope))
		local ok_commit, err = fibers.perform(mgr:submit_op({
			config = 'network',
			replace_package = true,
			changes = {
				{ op = 'set', config = 'network', section = 'lan', option = 'interface' },
				{ op = 'set', config = 'network', section = 'lan', option = 'proto', value = 'static' },
			},
		}))
		ok(ok_commit, err)
		local seen_delete_old, seen_delete_lan, seen_set_lan = false, false, false
		for _, c in ipairs(calls) do
			if c.op == 'delete' and c[1] == 'network' and c[2] == 'old' then seen_delete_old = true end
			if c.op == 'delete' and c[1] == 'network' and c[2] == 'lan' then seen_delete_lan = true end
			if c.op == 'set' and c[1] == 'network' and c[2] == 'lan' and c[3] == 'interface' then seen_set_lan = true end
		end
		ok(seen_delete_old, 'old section should be removed')
		ok(seen_delete_lan, 'surviving section should be recreated to drop stale options')
		ok(seen_set_lan, 'desired section should be written after delete')
	end)
end

function tests.test_manager_creates_missing_package_files_before_transaction()
	fibers.run(function (scope)
		local tmp = os.tmpname()
		os.remove(tmp)
		local calls = {}
		local cursor = fake_cursor(calls)
		cursor.get_all = function (_, _pkg) return {} end
		local mgr = ok(uci_manager.new({ confdir = tmp, cursor = cursor, run_cmd = function () return true end }))
		ok(mgr:start(scope))
		local result = fibers.perform(mgr:transaction_op({
			packages = { 'network', 'dhcp' },
			records = {
				{ config = 'network', replace_package = true, changes = {} },
				{ config = 'dhcp', replace_package = true, changes = {} },
			},
		}))
		ok(result and result.ok == true, result and result.err)
		local f = io.open(tmp .. '/network', 'rb')
		ok(f, 'network file should be created')
		f:close()
		f = io.open(tmp .. '/dhcp', 'rb')
		ok(f, 'dhcp file should be created')
		f:close()
		os.remove(tmp .. '/network'); os.remove(tmp .. '/dhcp'); os.remove(tmp)
	end)
end

function tests.test_activation_command_replies_without_waiting_for_command_completion()
	fibers.run(function(scope)
		local calls = {}
		local activation_restarts = {}
		local unblock_tx, unblock_rx = mailbox.new(1, { full = 'reject_newest' })
		local cursor = fake_cursor(calls)
		cursor.get_all = function (_, _pkg) return {} end
		local mgr = ok(uci_manager.new({
			cursor = cursor,
			debounce_s = 0.01,
			run_cmd = function (argv)
				activation_restarts[#activation_restarts + 1] = table.concat(argv, ' ')
				fibers.perform(unblock_rx:recv_op())
				return true, nil
			end,
		}))
		ok(mgr:start(scope))

		local result = { fibers.perform(mgr:transaction_op({
			packages = { 'network' },
			records = {
				{
					config = 'network',
					changes = { { op = 'set', config = 'network', section = 'lan', option = 'proto', value = 'static' } },
					restart_cmds = { { kind = 'reload', target = 'network', wait = false } },
				},
			},
		})) }

		eq(result[1].ok, true)
		ok(result[1].activation and result[1].activation.state == 'scheduled', 'activation should be scheduled')
		ok(probe.wait_until(function () return #activation_restarts == 1 end, { timeout = 0.5 }), 'activation runner should start command')
		eq(activation_restarts[1], '/etc/init.d/network reload')
		queue.try_admit_now(unblock_tx, true)
	end)
end

return tests
