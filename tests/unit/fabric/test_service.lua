-- tests/unit/fabric/test_service.lua

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local busmod = require 'bus'

local service = require 'services.fabric.service'
local topics  = require 'services.fabric.topics'
local cfg_mod = require 'services.fabric.config'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_true(v, msg)
	if v ~= true then
		fail(msg or ('expected true, got ' .. tostring(v)))
	end
end

local function assert_not_nil(v, msg)
	if v == nil then
		fail(msg or 'expected non-nil value')
	end
end

local function assert_nil(v, msg)
	if v ~= nil then
		fail(msg or ('expected nil, got ' .. tostring(v)))
	end
end

local function assert_eq(a, b, msg)
	if a ~= b then
		fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
	end
end

local function assert_match(s, pat, msg)
	if type(s) ~= 'string' or not s:match(pat) then
		fail(msg or ('expected "' .. tostring(s) .. '" to match ' .. tostring(pat)))
	end
end

local function run_service(params)
	return fibers.run_scope(function (scope)
		return service.run(scope, params)
	end)
end

local function one_component(name, role)
	return {
		name = name,

		run = function ()
			return {
				role = role or name,
			}
		end,
	}
end

-------------------------------------------------------------------------------
-- Successful static links complete the service
-------------------------------------------------------------------------------

function tests.test_successful_links_complete_service()
	fibers.run(function ()
		local st, rep, result = run_service {
			service_id = 'fabric-test',

			links = {
				{
					link_id = 'link-a',
					components = {
						one_component('reader'),
					},
				},

				{
					link_id = 'link-b',
					components = {
						one_component('writer'),
					},
				},
			},
		}

		assert_eq(st, 'ok')
		assert_eq(#rep.extra_errors, 0)
		assert_not_nil(result)

		local snap = result.snapshot

		assert_eq(snap.service_id, 'fabric-test')
		assert_eq(snap.state, 'completed')
		assert_eq(snap.completed, 2)
		assert_eq(snap.total, 2)

		assert_eq(snap.links['link-a'].status, 'ok')
		assert_eq(snap.links['link-b'].status, 'ok')
		assert_eq(snap.links['link-a'].snapshot.link_id, 'link-a')
		assert_eq(snap.links['link-b'].snapshot.link_id, 'link-b')
	end)
end

-------------------------------------------------------------------------------
-- Link failure is interpreted by the default service policy
-------------------------------------------------------------------------------

function tests.test_link_failure_fails_service_by_default_policy()
	fibers.run(function ()
		local st, rep, primary = run_service {
			service_id = 'fabric-test',

			links = {
				{
					link_id = 'bad-link',
					components = {
						{
							name = 'reader',
							run = function ()
								error('reader exploded', 0)
							end,
						},
					},
				},

				{
					link_id = 'slow-link',
					components = {
						{
							name = 'slow',
							run = function ()
								fibers.perform(sleep.sleep_op(10))
								return {
									role = 'slow',
								}
							end,
						},
					},
				},
			},
		}

		assert_eq(st, 'failed')
		assert_not_nil(rep)
		assert_match(primary, 'link bad%-link failed')
		assert_match(primary, 'component reader failed')
		assert_match(primary, 'reader exploded')
	end)
end

-------------------------------------------------------------------------------
-- Link failure can be treated as data by explicit service policy
-------------------------------------------------------------------------------

function tests.test_link_failure_is_data_when_policy_allows_it()
	fibers.run(function ()
		local seen_failed = false

		local st, rep, result = run_service {
			service_id = 'fabric-test',

			policy = function (_, ev)
				if ev.kind == 'link_done'
					and ev.link_id == 'bad-link'
					and ev.status == 'failed'
				then
					seen_failed = true
				end

				return {
					action = 'continue',
				}
			end,

			links = {
				{
					link_id = 'bad-link',
					components = {
						{
							name = 'reader',
							run = function ()
								error('reader failed as data', 0)
							end,
						},
					},
				},

				{
					link_id = 'good-link',
					components = {
						one_component('writer'),
					},
				},
			},
		}

		assert_eq(st, 'ok')
		assert_eq(#rep.extra_errors, 0)
		assert_true(seen_failed)

		local snap = result.snapshot

		assert_eq(snap.state, 'completed')
		assert_eq(snap.completed, 2)
		assert_eq(snap.links['bad-link'].status, 'failed')
		assert_match(snap.links['bad-link'].primary, 'reader failed as data')
		assert_eq(snap.links['good-link'].status, 'ok')
	end)
end

-------------------------------------------------------------------------------
-- Link cancellation is unexpected by default
-------------------------------------------------------------------------------

function tests.test_link_cancellation_fails_service_by_default_policy()
	fibers.run(function ()
		local st, _, primary = run_service {
			service_id = 'fabric-test',

			links = {
				{
					link_id = 'cancelled-link',
					components = {
						{
							name = 'session',

							run = function (component_scope)
								component_scope:cancel('session stopped')
								fibers.perform(sleep.sleep_op(10))

								return {
									unreachable = true,
								}
							end,
						},
					},
				},
			},
		}

		assert_eq(st, 'failed')
		assert_match(primary, 'link cancelled%-link failed')
		assert_match(primary, 'component session cancelled unexpectedly')
		assert_match(primary, 'session stopped')
	end)
end

-------------------------------------------------------------------------------
-- Service validates duplicate link ids before work begins
-------------------------------------------------------------------------------

function tests.test_duplicate_link_ids_are_rejected()
	fibers.run(function ()
		local st, _, primary = run_service {
			service_id = 'fabric-test',

			links = {
				{
					link_id = 'dup',
					components = {
						one_component('a'),
					},
				},

				{
					link_id = 'dup',
					components = {
						one_component('b'),
					},
				},
			},
		}

		assert_eq(st, 'failed')
		assert_match(primary, 'duplicate link id')
	end)
end

-------------------------------------------------------------------------------
-- Service result exposes a snapshot, not a live model
-------------------------------------------------------------------------------

function tests.test_service_result_exposes_snapshot_not_live_model()
	fibers.run(function ()
		local st, _, result = run_service {
			service_id = 'fabric-test',

			links = {
				{
					link_id = 'link-a',
					components = {
						one_component('reader'),
					},
				},
			},
		}

		assert_eq(st, 'ok')
		assert_not_nil(result.snapshot)
		assert_eq(result.model, nil)
	end)
end


-------------------------------------------------------------------------------
-- Complete policy may not finish while links are still live
-------------------------------------------------------------------------------

function tests.test_complete_policy_before_all_links_fails_service()
	fibers.run(function ()
		local st, _, primary = run_service {
			service_id = 'fabric-test',

			policy = function (_, ev)
				if ev.kind == 'link_done' and ev.link_id == 'fast-link' then
					return {
						action = 'complete',
						reason = 'not_all_done',
					}
				end

				return {
					action = 'continue',
				}
			end,

			links = {
				{
					link_id = 'fast-link',
					components = {
						one_component('fast'),
					},
				},

				{
					link_id = 'slow-link',
					components = {
						{
							name = 'slow',
							run = function ()
								fibers.perform(sleep.sleep_op(10))
								return {
									role = 'slow',
								}
							end,
						},
					},
				},
			},
		}

		assert_eq(st, 'failed')
		assert_match(primary, 'complete policy before all links completed')
	end)
end


-------------------------------------------------------------------------------
-- Cancel policy state is not regressed by later link completions
-------------------------------------------------------------------------------

function tests.test_cancel_policy_state_does_not_regress_after_later_completion()
	fibers.run(function ()
		local st, _, result = run_service {
			service_id = 'fabric-cancel-regression',

			link_runner = function (link_scope, spec)
				if spec.link_id == 'slow-link' then
					fibers.perform(sleep.sleep_op(10))
				end

				return {
					link_id = spec.link_id,
					role = spec.link_id,
				}
			end,

			policy = function (_, ev)
				if ev.kind == 'link_done' and ev.link_id == 'fast-link' then
					return {
						action = 'cancel',
						reason = 'stop after fast link',
					}
				end

				return { action = 'continue' }
			end,

			links = {
				{ link_id = 'fast-link' },
				{ link_id = 'slow-link' },
			},
		}

		assert_eq(st, 'ok')
		assert_eq(result.snapshot.state, 'cancelling')
		assert_eq(result.snapshot.reason, 'stop after fast link')
		assert_eq(result.snapshot.completed, 2)
		assert_eq(result.snapshot.links['fast-link'].status, 'ok')
		assert_eq(result.snapshot.links['slow-link'].status, 'cancelled')
	end)
end


-------------------------------------------------------------------------------
-- Link runners receive narrowed service capabilities, not the service coordinator
-------------------------------------------------------------------------------

function tests.test_link_runner_receives_narrowed_service_capability()
	fibers.run(function ()
		local saw_caps = false

		local st, _, result = run_service {
			service_id = 'fabric-service-cap-test',

			link_runner = function (_, spec, caps)
				saw_caps = true
				assert_eq(spec.link_id, 'link-cap-a')
				assert_eq(caps.service_id, 'fabric-service-cap-test')
				assert_eq(caps._model, nil)
				assert_eq(caps._links, nil)
				assert_eq(caps._done_tx, nil)
				assert_eq(type(caps.snapshot), 'table')
				return { role = 'link-runner' }
			end,

			links = {
				{ link_id = 'link-cap-a' },
			},
		}

		assert_eq(st, 'ok')
		assert_true(saw_caps)
		assert_eq(result.snapshot.links['link-cap-a'].status, 'ok')
	end)
end



-------------------------------------------------------------------------------
-- Public start shell: config-driven generation lifecycle
-------------------------------------------------------------------------------

local function start_shell_in_scope(scope, conn, opts)
	local ok, err = scope:spawn(function ()
		service.start(conn, opts)
	end)
	assert_true(ok, tostring(err))
end

local function minimal_compiled_config(link_id)
	return {
		schema = cfg_mod.SCHEMA,
		local_node = 'host-a',
		links = {
			{
				id = link_id or 'link-a',
				peer_id = 'peer-a',
				bridge = {},
			},
		},
	}
end

function tests.test_start_shell_loads_retained_config_and_starts_generation()
	fibers.run(function ()
		local bus = busmod.new()
		local conn = bus:connect()
		local seen = false
		local saw_transfer_rx = false
		local done_tx, done_rx = require('fibers.mailbox').new(1, { full = 'reject_newest' })

		conn:retain(topics.cfg(), minimal_compiled_config('link-started'))

		local st, _, primary = fibers.run_scope(function (scope)
			start_shell_in_scope(scope, conn, {
				link_runner = function (_, spec)
					seen = true
					saw_transfer_rx = spec.transfer_admission_rx ~= nil
					done_tx:send(true)
					return { role = 'test-link' }
				end,
			})

			local ok = fibers.perform(done_rx:recv_op())
			assert_true(ok)
			scope:cancel('test complete')
		end)

		assert_eq(st, 'cancelled', tostring(primary))
		assert_true(seen)
		assert_eq(saw_transfer_rx, false)
	end)
end

function tests.test_start_shell_replaces_generation_on_config_change()
	fibers.run(function ()
		local bus = busmod.new()
		local conn = bus:connect()
		local mailbox = require 'fibers.mailbox'
		local cond = require 'fibers.cond'
		local ready_tx, ready_rx = mailbox.new(4, { full = 'reject_newest' })
		local old_finalised = cond.new()
		local old_final_status
		local seen = {}

		conn:retain(topics.cfg(), minimal_compiled_config('link-old'))

		local st, _, primary = fibers.run_scope(function (scope)
			start_shell_in_scope(scope, conn, {
				link_runner = function (link_scope, spec)
					seen[#seen + 1] = spec.link_id
					ready_tx:send(spec.link_id)

					if spec.link_id == 'link-old' then
						link_scope:finally(function (_, status, primary)
							old_final_status = { status = status, primary = primary }
							old_finalised:signal()
						end)
						fibers.perform(sleep.sleep_op(10))
					end

					return { role = 'generation-link', link_id = spec.link_id }
				end,
			})

			assert_eq(fibers.perform(ready_rx:recv_op()), 'link-old')

			conn:retain(topics.cfg(), minimal_compiled_config('link-new'))

			assert_eq(fibers.perform(ready_rx:recv_op()), 'link-new')
			fibers.perform(old_finalised:wait_op())
			assert_not_nil(old_final_status)
			assert_eq(old_final_status.status, 'cancelled')

			scope:cancel('test complete')
		end)

		assert_eq(st, 'cancelled', tostring(primary))
		assert_eq(seen[1], 'link-old')
		assert_eq(seen[2], 'link-new')
	end)
end


function tests.test_public_transfer_manager_uses_scoped_request_cancellation()
	local f = assert(io.open('../src/services/fabric/service.lua', 'r'))
	local src = f:read('*a'); f:close()
	if not src:find("devicecode.support.request_owner", 1, true) then fail('fabric service should use request_owner for public transfer requests') end
	if not src:find("kind = 'public_transfer_request_done'", 1, true) then fail('public transfer requests should be admitted as scoped work') end
	if not src:find('cancel_op = owner:caller_cancel_op()', 1, true) then fail('public transfer requests should propagate caller cancellation') end
end

return tests
