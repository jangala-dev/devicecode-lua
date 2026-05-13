-- tests/integration/devhost/device_public_seams_spec.lua
--
-- Device public seam tests.  These drive the service through retained raw truth
-- and public component capability RPCs, without touching coordinator internals.

local busmod = require 'bus'
local fibers = require 'fibers'

local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'

local device_service = require 'services.device.service'
local topics         = require 'services.device.topics'
local device_config  = require 'services.device.config'
local fabric_topics  = require 'services.fabric.topics'

local T = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end

local function wait_retained_payload_where(conn, topic, label, pred, opts)
	opts = opts or {}
	local view = conn:retained_view(topic)
	local value = probe.wait_versioned_until(label, function ()
		return view:version()
	end, function (seen)
		return view:changed_op(seen)
	end, function ()
		local msg = view:get(topic)
		local payload = msg and msg.payload or nil
		if pred(payload) then return payload end
		return nil
	end, opts)
	view:close()
	return value
end


local function mcu_config(extra)
	extra = extra or {}
	local actions = extra.actions or {
		['stage-update'] = {
			kind = 'fabric_stage',
			receiver = topics.raw_member_cap_rpc('mcu', 'updater', 'main', 'stage-update'),
		},
	}
	return {
		schema = device_config.SCHEMA,
		components = {
			mcu = {
				class = 'member',
				subtype = 'mcu',
				member = 'mcu',
				facts = {
					software = topics.raw_member_state('mcu', 'software'),
					updater = topics.raw_member_state('mcu', 'updater'),
				},
				actions = actions,
			},
		},
	}
end

local function start_device(scope, params)
	params = params or {}
	local bus = params.bus or busmod.new()
	local svc_conn = bus:connect()
	local caller = bus:connect()
	local child = assert(scope:child())
	local ok, err = child:spawn(function ()
		device_service.start(svc_conn, {
			watch_config = false,
			initial_config = params.config or mcu_config(params.config_extra),
			enable_observers = true,
			enable_actions = true,
			auto_publish = true,
			fabric_client = params.fabric_client,
			action_timeout = params.action_timeout or 1.0,
		})
	end)
	assert_true(ok, err)

	probe.wait_retained_payload(caller, topics.components(), { timeout = 1.0 })
	return {
		bus = bus,
		child = child,
		caller = caller,
		svc_conn = svc_conn,
	}
end

local function transfer_client_for(conn)
	return {
		send_blob_op = function (_, source, meta, opts)
			return conn:call_op(fabric_topics.transfer_manager_rpc('send-blob'), {
				source = source,
				meta = meta,
				receiver = meta and meta.receiver,
				link_id = meta and meta.link_id,
			}, { timeout = opts and opts.timeout or 1.0 }):wrap(function (reply, err)
				if reply == nil then return nil, err end
				return reply.result or reply
			end)
		end,
	}
end

function T.device_observes_raw_member_truth_and_publishes_canonical_component_state()
	runfibers.run(function(scope)
		local h = start_device(scope)
		local conn = h.caller

		conn:retain(topics.raw_member_state('mcu', 'software'), {
			version = '1.2.3',
			build_id = 'abc123',
			image_id = 'mcu-image-1',
			boot_id = 'mcu-boot-1',
		})
		conn:retain(topics.raw_member_state('mcu', 'updater'), {
			state = 'ready',
			last_error = nil,
			pending_version = nil,
			pending_image_id = nil,
			staged_image_id = nil,
			job_id = nil,
		})

		local component = wait_retained_payload_where(conn, topics.component('mcu'), 'mcu component software observed', function (p)
			return p and p.software and p.software.version == '1.2.3' and p.updater and p.updater.state == 'ready'
		end, { timeout = 1.0 })
		assert_eq(component.kind, 'device.component')
		assert_eq(component.component, 'mcu')
		assert_eq(component.software.version, '1.2.3')
		assert_eq(component.updater.state, 'ready')

		local software = wait_retained_payload_where(conn, topics.component_software('mcu'), 'mcu software projection observed', function (p)
			return p and p.version == '1.2.3'
		end, { timeout = 1.0 })
		assert_eq(software.kind, 'device.component.software')
		assert_eq(software.component, 'mcu')
		assert_eq(software.version, '1.2.3')

		local meta = probe.wait_retained_payload(conn, topics.component_cap_meta('mcu'), { timeout = 1.0 })
		assert_eq(meta.owner, 'device')
		assert_eq(meta.canonical_state[1], 'state')
		assert_eq(meta.canonical_state[2], 'device')
		assert_eq(meta.canonical_state[3], 'component')
		assert_eq(meta.canonical_state[4], 'mcu')
		assert_eq(meta.backing.facts.software[1], 'raw')
		assert_eq(meta.backing.facts.software[2], 'member')
		assert_eq(meta.backing.facts.software[3], 'mcu')

		h.child:cancel('test complete')
	end, { timeout = 5.0 })
end

function T.device_stage_update_calls_public_transfer_manager_capability()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local caller = bus:connect()
		local source_terminated = 0
		local receiver_installed = 0
		local seen_request

		local transfer_ep = caller:bind(fabric_topics.transfer_manager_rpc('send-blob'), {
			queue_len = 4,
		})
		local ok, err = scope:spawn(function ()
			local req = transfer_ep:recv()
			seen_request = req and req.payload
			if req then
				req:reply({
					ok = true,
					result = {
						ok = true,
						reply_payload = { staged = true, receiver = seen_request and seen_request.receiver },
						source_handoff = {
							consumed = true,
							receiver_install = function (src)
								receiver_installed = receiver_installed + 1
								assert_not_nil(src)
								return true, nil
							end,
						},
					},
				})
			end
		end)
		assert_true(ok, err)

		local h = start_device(scope, {
			bus = bus,
			fabric_client = transfer_client_for(caller),
		})
		local conn = h.caller
		probe.wait_retained_payload(conn, topics.component_cap_meta('mcu'), { timeout = 1.0 })
		local source = {
			read_chunk_op = function () return fibers.always(nil, nil) end,
			terminate = function () source_terminated = source_terminated + 1; return true, nil end,
		}

		local reply, call_err = conn:call(topics.component_cap_rpc('mcu', 'stage-update'), {
			source = source,
		}, { timeout = 1.0 })
		assert_not_nil(reply, call_err)
		assert_eq(reply.staged, true)
		assert_eq(reply.receiver[1], 'raw')
		assert_eq(reply.receiver[2], 'member')
		assert_eq(reply.receiver[3], 'mcu')
		assert_not_nil(seen_request)
		assert_eq(seen_request.receiver[1], 'raw')
		assert_eq(source_terminated, 0, 'device must release cleanup after receiver handoff')
		assert_eq(receiver_installed, 1)

		local component = wait_retained_payload_where(conn, topics.component('mcu'), 'mcu stage action recorded', function (p)
			return p and p.last_action and p.last_action.action == 'stage-update'
		end, { timeout = 1.0 })
		assert_not_nil(component.last_action)
		assert_eq(component.last_action.action, 'stage-update')
		assert_eq(component.last_action.ok, true)
		assert_nil(component.last_action.result.source_handoff)

		h.child:cancel('test complete')
	end, { timeout = 5.0 })
end

return T
