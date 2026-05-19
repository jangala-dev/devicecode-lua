-- services/fabric/bus_adapter.lua
--
-- Local bus adapter for Fabric bridge semantics.
--
-- Owns local-bus subscriptions, retained watches, endpoint bindings, imported
-- publication/unretain, and local RPC calls on behalf of remote Fabric peers.

local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'

local queue          = require 'devicecode.support.queue'
local service_events = require 'devicecode.support.service_events'
local scoped_work    = require 'devicecode.support.scoped_work'
local priority_event = require 'devicecode.support.priority_event'
local bus_cleanup    = require 'devicecode.support.bus_cleanup'
local topics         = require 'services.fabric.topics'
local session_mod    = require 'services.fabric.session'

local M = {}

local DEFAULT_CALL_TIMEOUT      = 1.0
local DEFAULT_LOCAL_EVENT_QUEUE = 64
local DEFAULT_COMMAND_QUEUE     = 64

local function close_list(conn, list, close_fn, label)
	local first_err

	for i = #list, 1, -1 do
		local item = list[i]
		list[i] = nil

		local ok, err = close_fn(conn, item)
		if ok ~= true and first_err == nil then
			first_err = err or label
		end
	end

	if first_err then
		return nil, first_err
	end

	return true, nil
end

local function checked_topic(v, label)
	if type(v) ~= 'table' then
		return nil, label
	end
	return topics.copy(v), nil
end

local function rule_watch_topic(rule)
	return checked_topic(
		type(rule) == 'table' and rule.local_watch_topic or nil,
		'fabric bus adapter rule has no local_watch_topic'
	)
end

local function rule_call_topic(rule)
	return checked_topic(
		type(rule) == 'table' and rule.local_topic or nil,
		'fabric bus adapter outbound call rule has no local_topic'
	)
end

local function origin_kind(cmd)
	if type(cmd.origin_kind) ~= 'string' or cmd.origin_kind == '' then
		error('fabric bus adapter command missing origin_kind', 0)
	end

	return cmd.origin_kind
end

local function origin_extra(params, kind, item)
	local fabric = {
		kind            = kind,
		link_id         = params.link_id,
		link_generation = params.link_generation or params.generation,
	}

	if type(item) == 'table' and item.session ~= nil then
		fabric.session = session_mod.copy_context(item.session)
	end

	local frame = item and item.frame or item
	if type(frame) == 'table' then
		fabric.call_id    = frame.id
		fabric.frame_type = frame.type
	end

	return { fabric = fabric }
end

local function reply_once(cmd)
	local done = false

	return function (value, label)
		if done then
			return false, 'already_replied'
		end

		done = true

		if cmd.reply_tx == nil then
			return true, nil
		end

		return queue.try_admit_required(
			cmd.reply_tx,
			value,
			label or 'fabric_bus_adapter_call_reply_failed'
		)
	end,
	function ()
		return done
	end
end

function M.local_runtime(scope, conn, params)
	if type(scope) ~= 'table' then
		error('fabric.bus_adapter.local_runtime: scope required', 2)
	end
	if type(conn) ~= 'table' then
		error('fabric.bus_adapter.local_runtime: conn required', 2)
	end

	params = params or {}

	local local_tx, local_rx = mailbox.new(
		params.local_queue_len or DEFAULT_LOCAL_EVENT_QUEUE,
		{ full = 'reject_newest' }
	)

	local command_tx, command_rx = mailbox.new(
		params.bus_command_queue_len or params.command_queue_len or DEFAULT_COMMAND_QUEUE,
		{ full = 'reject_newest' }
	)

	local done_tx, done_rx = mailbox.new(
		params.bus_call_done_queue_len or params.call_done_queue_len or DEFAULT_COMMAND_QUEUE,
		{ full = 'reject_newest' }
	)

	local runtime = {
		local_rx    = local_rx,
		command_tx  = command_tx,

		_subs       = {},
		_watches    = {},
		_eps        = {},
		_calls      = {},
		_call_count = 0,
		_closed     = false,
		_command_loop_started = false,
	}

	local function cancel_calls(reason)
		for _, rec in pairs(runtime._calls) do
			if rec.handle and rec.handle.cancel then
				rec.handle:cancel(reason or 'fabric bus adapter closing')
			end
		end
	end

	local function terminate(_, reason)
		if runtime._closed then
			return true, nil
		end

		runtime._closed = true
		cancel_calls(reason or 'fabric bus adapter runtime closed')

		local first_err
		local ok, err

		ok, err = close_list(conn, runtime._eps, bus_cleanup.unbind, 'fabric bus adapter endpoint cleanup failed')
		if ok ~= true and first_err == nil then first_err = err end

		ok, err = close_list(conn, runtime._watches, bus_cleanup.unwatch_retained, 'fabric bus adapter retained-watch cleanup failed')
		if ok ~= true and first_err == nil then first_err = err end

		ok, err = close_list(conn, runtime._subs, bus_cleanup.unsubscribe, 'fabric bus adapter subscription cleanup failed')
		if ok ~= true and first_err == nil then first_err = err end

		local why = reason or first_err or 'fabric bus adapter runtime closed'
		local_tx:close(why)
		command_tx:close(why)

		-- Once the command loop has started it owns done_tx until it has
		-- drained active call completions. Closing it here can race the loop
		-- into seeing call_done_closed before command_closed, turning orderly
		-- runtime termination into a coordinator failure. During setup failure,
		-- before the command loop exists, terminate still closes done_tx.
		if not runtime._command_loop_started then
			done_tx:close(why)
		end

		if first_err then
			return nil, first_err
		end

		return true, nil
	end

	runtime.terminate = terminate

	local function abort_setup(err)
		runtime:terminate('fabric bus adapter runtime setup failed')
		error(err, 3)
	end

	local function admit_local(ev, label)
		queue.assert_admit_required(local_tx, ev, label, 3)
	end

	local function subscribe(rule, retained)
		local topic, err = rule_watch_topic(rule)
		if not topic then abort_setup(err) end

		local handle, herr
		if retained then
			handle, herr = bus_cleanup.watch_retained(conn, topic, {
				replay    = true,
				queue_len = params.local_feed_queue_len,
				full      = params.local_feed_full or 'reject_newest',
			})
		else
			handle, herr = bus_cleanup.subscribe(conn, topic, {
				queue_len = params.local_feed_queue_len,
				full      = params.local_feed_full or 'reject_newest',
			})
		end

		if not handle then
			abort_setup(herr or 'fabric bus adapter local feed setup failed')
		end

		if retained then
			runtime._watches[#runtime._watches + 1] = handle

			local ok_spawn, spawn_err = fibers.spawn(function ()
				while true do
					local ev = fibers.perform(handle:recv_op())
					if ev == nil then return end

					if ev.op == 'retain' then
						admit_local({
							kind    = 'publish',
							topic   = ev.topic,
							payload = ev.payload,
							retain  = true,
						}, 'fabric_bus_adapter_retained_event_admit_failed')

					elseif ev.op == 'unretain' then
						admit_local({
							kind  = 'unretain',
							topic = ev.topic,
						}, 'fabric_bus_adapter_unretain_event_admit_failed')

					elseif ev.op ~= 'replay_done' then
						error('fabric bus adapter retained watch unknown event: ' .. tostring(ev.op), 0)
					end
				end
			end)
			if not ok_spawn then
				abort_setup('fabric bus adapter retained source spawn failed: ' .. tostring(spawn_err))
			end

		else
			runtime._subs[#runtime._subs + 1] = handle

			local ok_spawn, spawn_err = fibers.spawn(function ()
				while true do
					local msg = fibers.perform(handle:recv_op())
					if msg == nil then return end

					admit_local({
						kind    = 'publish',
						topic   = msg.topic,
						payload = msg.payload,
						retain  = false,
					}, 'fabric_bus_adapter_publish_event_admit_failed')
				end
			end)
			if not ok_spawn then
				abort_setup('fabric bus adapter publish source spawn failed: ' .. tostring(spawn_err))
			end
		end
	end

	local function bind(rule)
		local topic, err = rule_call_topic(rule)
		if not topic then abort_setup(err) end

		local ep, eerr = bus_cleanup.bind(conn, topic, {
			queue_len = params.local_endpoint_queue_len or 1,
		})
		if not ep then abort_setup(eerr or 'fabric bus adapter bind failed') end

		runtime._eps[#runtime._eps + 1] = ep

		local ok_spawn, spawn_err = fibers.spawn(function ()
			while true do
				local req = fibers.perform(ep:recv_op())
				if req == nil then return end

				local ok, admit_err = queue.try_admit_required(local_tx, {
					kind               = 'call',
					topic              = req.topic,
					payload            = req.payload,
					timeout            = rule.timeout or params.call_timeout_s,
					reply_policy      = rule.reply_policy,
					request            = req,
					reply_payload_only = true,
				}, 'fabric_bus_adapter_call_event_admit_failed')

				if ok ~= true then
					bus_cleanup.fail(req, 'fabric_bus_adapter_queue_full')
					error(admit_err or 'fabric_bus_adapter_call_event_admit_failed', 0)
				end
			end
		end)
		if not ok_spawn then
			abort_setup('fabric bus adapter endpoint source spawn failed: ' .. tostring(spawn_err))
		end
	end

	local function publish_to_bus(cmd)
		local opts = {
			extra = origin_extra(params, origin_kind(cmd), cmd),
		}

		if cmd.kind == 'retain' then
			return bus_cleanup.retain(conn, cmd.topic, cmd.payload, opts)
		end

		return bus_cleanup.publish(conn, cmd.topic, cmd.payload, opts)
	end

	local function unretain_from_bus(cmd)
		return bus_cleanup.unretain(conn, cmd.topic, {
			extra = origin_extra(params, origin_kind(cmd), cmd),
		})
	end

	local function start_call(cmd, seq)
		local key = 'bus-call-' .. tostring(seq)
		local reply, replied = reply_once(cmd)

		local handle, err = scoped_work.start {
			lifetime_scope = scope,
			reaper_scope   = scope,
			report_scope   = scope,

			identity = {
				kind     = 'call_done',
				call_key = key,
			},

			run = function (call_scope)
				call_scope:finally(function (_, status, primary)
					reply({
						ok  = false,
						err = tostring(primary or status or 'local_call_closed'),
					}, 'fabric_bus_adapter_call_final_reply_failed')
				end)

				local value, call_err = fibers.perform(conn:call_op(cmd.topic, cmd.payload, {
					timeout = cmd.timeout or params.call_timeout_s or DEFAULT_CALL_TIMEOUT,
					extra   = origin_extra(params, origin_kind(cmd), cmd),
				}))

				if value == nil then
					local reason = call_err or 'local_call_failed'
					reply({ ok = false, err = reason }, 'fabric_bus_adapter_call_reply_failed')
					return { ok = false, err = reason }
				end

				reply({ ok = true, payload = value }, 'fabric_bus_adapter_call_reply_failed')
				return { ok = true }
			end,

			report = service_events.reporter_for(
				done_tx,
				{
					kind = 'call_done',
					call_key = key,
					source = 'fabric_bus_adapter_call',
					source_id = key,
				},
				{ label = 'fabric_bus_adapter_call_completion_report_failed' }
			),
		}

		if not handle then
			reply({
				ok  = false,
				err = err or 'local_call_start_failed',
			}, 'fabric_bus_adapter_call_start_reply_failed')

			return nil, err or 'local_call_start_failed'
		end

		runtime._calls[key] = {
			handle  = handle,
			reply   = reply,
			replied = replied,
		}
		runtime._call_count = runtime._call_count + 1

		return true, nil, seq + 1
	end

	local function command_event(cmd)
		return cmd and { kind = 'command', cmd = cmd } or { kind = 'command_closed' }
	end

	local function done_event(ev)
		return ev or { kind = 'call_done_closed' }
	end

	local function try_recv(rx, map)
		local item, err = queue.try_recv_now(rx)

		if item ~= nil then
			return map(item)
		end

		if err ~= 'not_ready' then
			return map(nil)
		end

		return nil
	end

	local function command_loop()
		local command_open = true
		local pending = {}
		local seq = 1

		scope:finally(function (_, status, primary)
			local why = primary or status or 'fabric bus adapter command loop closed'
			cancel_calls(why)
			done_tx:close(why)
		end)

		local function next_event_op()
			return priority_event.sources_op {
				label   = 'fabric.bus_adapter.commands',
				pending = pending,
				sources = {
					{
						name = 'done',
						try_now = function () return try_recv(done_rx, done_event) end,
						recv_op = function () return done_rx:recv_op():wrap(done_event) end,
					},
					{
						name = 'command',
						enabled = function () return command_open end,
						try_now = function () return try_recv(command_rx, command_event) end,
						recv_op = function () return command_rx:recv_op():wrap(command_event) end,
					},
				},
			}
		end

		while command_open or runtime._call_count > 0 do
			local ev = fibers.perform(next_event_op())

			if ev.kind == 'command_closed' then
				command_open = false
				cancel_calls('fabric bus adapter command queue closed')

			elseif ev.kind == 'call_done_closed' then
				if command_open or runtime._call_count > 0 then
					error('fabric bus adapter call completion queue closed', 0)
				end

			elseif ev.kind == 'call_done' then
				local rec = runtime._calls[ev.call_key]
				if rec then
					runtime._calls[ev.call_key] = nil
					runtime._call_count = runtime._call_count - 1

					if ev.status ~= 'ok' and not rec.replied() then
						rec.reply({
							ok  = false,
							err = tostring(ev.primary or ev.status or 'local_call_failed'),
						}, 'fabric_bus_adapter_call_done_reply_failed')
					end
				end

			elseif ev.kind == 'command' then
				local cmd = ev.cmd
				local ok, err

				if cmd.kind == 'publish' or cmd.kind == 'retain' then
					ok, err = publish_to_bus(cmd)

				elseif cmd.kind == 'unretain' then
					ok, err = unretain_from_bus(cmd)

				elseif cmd.kind == 'call' then
					ok, err, seq = start_call(cmd, seq)

				elseif cmd.kind == 'stop' then
					command_open = false
					cancel_calls('fabric bus adapter stopped')
					ok = true

				else
					error('fabric bus adapter unknown command: ' .. tostring(cmd.kind), 0)
				end

				if ok ~= true then
					error(err or ('fabric bus adapter command failed: ' .. tostring(cmd.kind)), 0)
				end

			else
				error('fabric bus adapter unknown event: ' .. tostring(ev.kind), 0)
			end
		end

		done_tx:close('fabric bus adapter command loop completed')
	end

	for _, rule in ipairs(params.export_publish_rules or {}) do
		subscribe(rule, false)
	end

	for _, rule in ipairs(params.export_retained_rules or {}) do
		subscribe(rule, true)
	end

	for _, rule in ipairs(params.outbound_call_rules or {}) do
		bind(rule)
	end

	local ok_spawn, spawn_err = fibers.spawn(command_loop)
	if not ok_spawn then
		abort_setup('fabric bus adapter command loop spawn failed: ' .. tostring(spawn_err))
	end
	runtime._command_loop_started = true

	scope:finally(function ()
		local ok, err = runtime:terminate('fabric bus adapter scope closed')
		if ok ~= true then
			error(err or 'fabric bus adapter cleanup failed', 0)
		end
	end)

	return runtime
end

return M
