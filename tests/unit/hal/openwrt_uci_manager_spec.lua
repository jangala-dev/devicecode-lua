local run_virtual_fibers = require 'tests.support.run_virtual_fibers'
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

local function section_record(name, stype, index, anonymous, options)
	local record = {
		['.name'] = name,
		['.type'] = stype,
		['.index'] = index,
		['.anonymous'] = anonymous == true,
	}
	for key, value in pairs(options or {}) do record[key] = value end
	return record
end

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
	run_virtual_fibers.run_auto(function (scope)
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
	run_virtual_fibers.run_auto(function (scope)
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
	run_virtual_fibers.run_auto(function ()
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
	run_virtual_fibers.run_auto(function (scope)
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
	run_virtual_fibers.run_auto(function (scope)
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
	run_virtual_fibers.run_auto(function (scope)
		local calls = {}
		local snapshots = {
			network = {
				lan = section_record('lan', 'interface', 0, false, { proto = 'static' }),
			},
			dhcp = {
				dnsmasq = section_record('dnsmasq', 'dnsmasq', 0, false, { domainneeded = '1' }),
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
	run_virtual_fibers.run_auto(function (scope)
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
	run_virtual_fibers.run_auto(function (scope)
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
	run_virtual_fibers.run_auto(function(scope)
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

local function cancellable_record(value)
	return { config = 'network', changes = {
		{ op = 'set', config = 'network', section = 'lan', option = 'proto', value = value },
	}, restart_cmds = { { kind = 'reload', target = 'network', wait = true } } }
end

function tests.test_queued_transaction_cancellation_discards_without_changes()
	require('tests.support.run_fibers').run(function(scope)
		local channel = require 'fibers.channel'
		local entered, release, admitted, done = channel.new(1), channel.new(1), channel.new(1), channel.new(1)
		local cancel = channel.new(1)
		local calls = {}
		local cursor = fake_cursor(calls)
		cursor.get_all = function() return {} end
		local mgr = ok(uci_manager.new({ cursor = cursor, run_cmd = function()
			entered:put(true)
			release:get()
			return true
		end }))
		ok(mgr:start(scope))
		ok(scope:spawn(function()
			fibers.perform(mgr:transaction_op({ records = { cancellable_record('first') } }))
		end))
		entered:get()
		ok(scope:spawn(function()
			done:put(fibers.perform(mgr:transaction_op({ records = { cancellable_record('obsolete') } }, {
				cancel_op = cancel:get_op(), on_admitted = function() admitted:put(true) end,
			})))
		end))
		admitted:get()
		cancel:put('superseded')
		release:put(true)
		local result = done:get()
		eq(result.status, 'cancelled_no_change')
		eq(result.rollback.attempted, false)
		for _, call in ipairs(calls) do
			if call.op == 'set' then eq(call[4], 'first') end
		end
	end)
end

function tests.test_cancellation_during_uncommitted_changes_reverts_without_rewriting_or_activation()
	require('tests.support.run_fibers').run(function(scope)
		local cancel = require('fibers.channel').new(1)
		local calls, activations, applied_after_cancel = {}, 0, false
		local cursor = fake_cursor(calls)
		local did_revert = false
		cursor.get_all = function()
			local anonymous_name = did_revert and 'cfgnew' or 'cfgold'
			return {
				lan = section_record('lan', 'interface', 0, false, { proto = 'original' }),
				[anonymous_name] = section_record(anonymous_name, 'rule', 1, true, { target = 'ACCEPT' }),
			}
		end
		local revert = cursor.revert
		cursor.revert = function(self, config)
			did_revert = true
			return revert(self, config)
		end
		local set = cursor.set
		cursor.set = function(self, config, section, option, value)
			if value == 'obsolete' then cancel:put('superseded') end
			if value == 'must_not_apply' then applied_after_cancel = true end
			return set(self, config, section, option, value)
		end
		local mgr = ok(uci_manager.new({ cursor = cursor, run_cmd = function()
			activations = activations + 1
			return true
		end }))
		ok(mgr:start(scope))
		local result = fibers.perform(mgr:transaction_op({
			records = { { config = 'network', changes = {
				{ op = 'set', config = 'network', section = 'lan', option = 'proto', value = 'obsolete' },
				{ op = 'set', config = 'network', section = 'lan', option = 'after_cancel', value = 'must_not_apply' },
			}, restart_cmds = { { kind = 'reload', target = 'network', wait = true } } } },
			rollback = false, reactivate_on_rollback = true,
		}, { cancel_op = cancel:get_op() }))
		eq(result.status, 'cancelled_no_change')
		eq(result.rollback.attempted, false)
		eq(activations, 0)
		eq(applied_after_cancel, false, 'changes after cancellation must not be applied')
		local reverted, rewrote = false, false
		for _, call in ipairs(calls) do
			if call.op == 'revert' then reverted = true end
			if call.op == 'delete' or call.op == 'commit' then rewrote = true end
		end
		ok(reverted, 'staged configuration should be reverted')
		eq(rewrote, false, 'equivalent configuration should not be rewritten')
	end)
end

function tests.test_invalid_cancel_op_is_rejected_without_admission_or_manager_failure()
	require('tests.support.run_fibers').run(function(scope)
		local calls = {}
		local cursor = fake_cursor(calls)
		cursor.get_all = function() return {} end
		local mgr = ok(uci_manager.new({ cursor = cursor, run_cmd = function() return true end }))
		ok(mgr:start(scope))

		local invalid, admitted = fibers.perform(mgr:transaction_op({
			records = { cancellable_record('invalid') },
		}, { cancel_op = {} }))
		eq(invalid.status, 'invalid')
		contains(invalid.err, 'cancel_op must be an Op')
		eq(admitted, false)
		eq(#calls, 0, 'invalid request must not reach the manager')

		local valid, valid_admitted = fibers.perform(mgr:transaction_op({
			records = { cancellable_record('valid') },
		}))
		eq(valid.status, 'ok')
		eq(valid_admitted, true)
	end)
end

function tests.test_cancellation_after_activation_starts_is_ignored()
	require('tests.support.run_fibers').run(function(scope)
		local cancel = require('fibers.channel').new(1)
		local calls, activations = {}, 0
		local cursor = fake_cursor(calls)
		cursor.get_all = function() return {} end
		local mgr = ok(uci_manager.new({ cursor = cursor, run_cmd = function()
			activations = activations + 1
			if activations == 1 then cancel:put('superseded') end
			return true
		end }))
		ok(mgr:start(scope))
		local record = cancellable_record('new')
		record.restart_cmds[2] = { kind = 'restart', target = 'firewall', wait = true }
		local result = fibers.perform(mgr:transaction_op({ records = { record } }, { cancel_op = cancel:get_op() }))
		eq(result.ok, true)
		eq(result.status, 'ok')
		eq(result.rollback.attempted, false)
		eq(activations, 2)
	end)
end

function tests.test_cancellation_after_commit_restores_committed_packages()
	require('tests.support.run_fibers').run(function(scope)
		local cancel = require('fibers.channel').new(1)
		local calls, commits, activations = {}, 0, 0
		local cursor = fake_cursor(calls)
		cursor.get_all = function()
			local proto = commits == 1 and 'obsolete' or 'original'
			return { lan = section_record('lan', 'interface', 0, false, { proto = proto }) }
		end
		cursor.reorder = function(_, ...)
			calls[#calls + 1] = { op = 'reorder', ... }
			return true
		end
		cursor.commit = function()
			commits = commits + 1
			if commits == 1 then cancel:put('superseded') end
			return true
		end
		local mgr = ok(uci_manager.new({ cursor = cursor, run_cmd = function()
			activations = activations + 1
			return true
		end }))
		ok(mgr:start(scope))
		local result = fibers.perform(mgr:transaction_op({ records = { cancellable_record('obsolete') } }, {
			cancel_op = cancel:get_op(),
		}))
		eq(result.status, 'cancelled_rolled_back')
		eq(result.rollback.ok, true)
		eq(commits, 2, 'rollback should commit the restored package')
		eq(activations, 0)
	end)
end

function tests.test_cancellation_restores_only_committed_packages_and_reverts_current_staging()
	require('tests.support.run_fibers').run(function(scope)
		local cancel = require('fibers.channel').new(1)
		local calls, commits = {}, {}
		local cursor = fake_cursor(calls)
		cursor.get_all = function(_, config)
			return { main = section_record('main', 'settings', 0, false, { value = config .. '-original' }) }
		end
		local set = cursor.set
		cursor.set = function(self, config, section, option, value)
			if config == 'firewall' and value == 'cancel-now' then cancel:put('superseded') end
			return set(self, config, section, option, value)
		end
		cursor.commit = function(_, config)
			commits[#commits + 1] = config
			calls[#calls + 1] = { op = 'commit', config }
			return true
		end
		local mgr = ok(uci_manager.new({ cursor = cursor, run_cmd = function() return true end }))
		ok(mgr:start(scope))
		local result = fibers.perform(mgr:transaction_op({
			packages = { 'network', 'firewall', 'dhcp' },
			records = {
				{ config = 'network', changes = {
					{ op = 'set', section = 'main', option = 'value', value = 'network-changed' },
				} },
				{ config = 'firewall', changes = {
					{ op = 'set', section = 'main', option = 'value', value = 'cancel-now' },
				} },
			},
		}, { cancel_op = cancel:get_op() }))
		eq(result.status, 'cancelled_rolled_back')
		eq(result.rollback.ok, true)
		eq(result.rollback.packages[1], 'network')
		eq(#result.rollback.packages, 1)
		eq(commits[1], 'network')
		eq(#commits, 1, 'cancelled firewall package must not be committed')

		local reverted = {}
		for _, call in ipairs(calls) do
			if call.op == 'revert' then reverted[call[1]] = true end
		end
		eq(reverted.network, true, 'committed package should be restored')
		eq(reverted.firewall, true, 'current staged package should be reverted')
		eq(reverted.dhcp, nil, 'uncommitted untouched package should not be restored')
	end)
end

function tests.test_restore_preserves_section_order_and_anonymity_and_ignores_generated_anonymous_ids()
	require('tests.support.run_fibers').run(function(scope)
		local cancel = require('fibers.channel').new(1)
		local calls, commits, anonymous = {}, 0, 0
		local snapshot = {
			cfgold1 = section_record('cfgold1', 'rule', 0, true, { target = 'ACCEPT' }),
			policy = section_record('policy', 'defaults', 1, false, { enabled = '1' }),
			cfgold2 = section_record('cfgold2', 'rule', 2, true, { target = 'REJECT' }),
		}
		local changed = {
			policy = section_record('policy', 'defaults', 0, false, { enabled = '0' }),
		}
		local restored = {
			cfgnew1 = section_record('cfgnew1', 'rule', 0, true, { target = 'ACCEPT' }),
			policy = section_record('policy', 'defaults', 1, false, { enabled = '1' }),
			cfgnew2 = section_record('cfgnew2', 'rule', 2, true, { target = 'REJECT' }),
		}
		local cursor = fake_cursor(calls)
		cursor.get_all = function()
			if commits == 0 then return snapshot end
			if commits == 1 then return changed end
			return restored
		end
		cursor.add = function(_, config, stype)
			anonymous = anonymous + 1
			local name = 'cfgnew' .. tostring(anonymous)
			calls[#calls + 1] = { op = 'add', config, stype, name }
			return name
		end
		cursor.reorder = function(_, ...)
			calls[#calls + 1] = { op = 'reorder', ... }
			return true
		end
		cursor.commit = function(_, config)
			commits = commits + 1
			calls[#calls + 1] = { op = 'commit', config }
			if commits == 1 then cancel:put('superseded') end
			return true
		end
		local mgr = ok(uci_manager.new({ cursor = cursor, run_cmd = function() return true end }))
		ok(mgr:start(scope))
		local result = fibers.perform(mgr:transaction_op({ records = {
			{ config = 'firewall', changes = {
				{ op = 'set', config = 'firewall', section = 'policy', option = 'enabled', value = '0' },
			} },
		} }, { cancel_op = cancel:get_op() }))
		eq(result.status, 'cancelled_rolled_back')
		eq(result.rollback.ok, true)
		eq(commits, 2)

		local created, reordered = {}, {}
		for _, call in ipairs(calls) do
			if call.op == 'add' then created[#created + 1] = 'anonymous:' .. tostring(call[2]) end
			if call.op == 'set' and call[4] == nil then created[#created + 1] = 'named:' .. tostring(call[2]) end
			if call.op == 'reorder' then reordered[#reordered + 1] = call[3] end
		end
		eq(created[1], 'anonymous:rule')
		eq(created[2], 'named:policy')
		eq(created[3], 'anonymous:rule')
		eq(reordered[1], 0)
		eq(reordered[2], 1)
		eq(reordered[3], 2)
	end)
end

function tests.test_cancellation_reports_rollback_failure()
	require('tests.support.run_fibers').run(function(scope)
		local cancel = require('fibers.channel').new(1)
		local cursor = fake_cursor({})
		local commits = 0
		cursor.get_all = function()
			local proto = commits == 0 and 'original' or 'obsolete'
			return { lan = section_record('lan', 'interface', 0, false, { proto = proto }) }
		end
		cursor.set = function(_, _, _, _, value)
			if value == 'original' then return nil, 'restore failed' end
			return true
		end
		cursor.commit = function()
			commits = commits + 1
			if commits == 1 then cancel:put('superseded') end
			return true
		end
		local mgr = ok(uci_manager.new({ cursor = cursor }))
		ok(mgr:start(scope))
		local result = fibers.perform(mgr:transaction_op({ records = { cancellable_record('obsolete') } }, {
			cancel_op = cancel:get_op(),
		}))
		eq(result.ok, false)
		eq(result.cancelled, true)
		eq(result.status, 'failed_rollback_failed')
		contains(result.rollback.err, 'restore failed')
	end)
end

return tests
