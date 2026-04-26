-- services/fabric/session_ctl.lua
--
-- Per-link session controller.
--
-- Owns:
--   * handshake state
--   * readiness state
--   * liveness state
--   * retained session subtree:
--       state/fabric/link/<id>/session
--
-- Important invariant:
--   ready == (established and rpc_ready)
--
-- Exported session state is derived:
--   * down          -> "down"
--   * ready         -> "ready"
--   * otherwise     -> "establishing"

local fibers    = require 'fibers'
local pulse_mod = require 'fibers.pulse'
local runtime   = require 'fibers.runtime'
local sleep     = require 'fibers.sleep'
local uuid      = require 'uuid'

local protocol  = require 'services.fabric.protocol'
local statefmt  = require 'services.fabric.statefmt'

local perform = fibers.perform
local named_choice = fibers.named_choice

local M = {}

local function derived_state(s)
	if s.down then
		return 'down'
	end
	if s.ready then
		return 'ready'
	end
	return 'establishing'
end

local function clone_snapshot(s)
	return {
		down = s.down,
		local_sid = s.local_sid,
		peer_sid = s.peer_sid,
		peer_node = s.peer_node,
		generation = s.generation,
		last_rx_at = s.last_rx_at,
		last_tx_at = s.last_tx_at,
		last_pong_at = s.last_pong_at,
		established = s.established,
		ready = s.ready,
	}
end

local function export_snapshot(s)
	local out = clone_snapshot(s)
	out.state = derived_state(s)
	return out
end

local function same_snapshot(a, b)
	if a == nil or b == nil then return a == b end
	return a.down == b.down
		and a.local_sid == b.local_sid
		and a.peer_sid == b.peer_sid
		and a.peer_node == b.peer_node
		and a.generation == b.generation
		and a.last_rx_at == b.last_rx_at
		and a.last_tx_at == b.last_tx_at
		and a.last_pong_at == b.last_pong_at
		and a.established == b.established
		and a.ready == b.ready
end

local function publish_state(conn, topic, link_id, snapshot)
	conn:retain(topic, statefmt.link_component('session', link_id, {
		state = derived_state(snapshot),
		local_sid = snapshot.local_sid,
		peer_sid = snapshot.peer_sid,
		peer_node = snapshot.peer_node,
		generation = snapshot.generation,
		last_rx_at = snapshot.last_rx_at,
		last_tx_at = snapshot.last_tx_at,
		last_pong_at = snapshot.last_pong_at,
		established = snapshot.established,
		ready = snapshot.ready,
	}))
end

function M.new_state(link_id, state_conn)
	local pulse = pulse_mod.new()
	local current = {
		down = false,
		local_sid = tostring(uuid.new()),
		peer_sid = nil,
		peer_node = nil,
		generation = 0,
		last_rx_at = nil,
		last_tx_at = nil,
		last_pong_at = nil,
		established = false,
		ready = false,
	}
	local last_published = nil
	local topic = statefmt.component_topic(link_id, 'session')

	local holder = {}

	local function maybe_publish(force)
		if force or not same_snapshot(current, last_published) then
			last_published = current
			publish_state(state_conn, topic, link_id, current)
		end
	end

	function holder:get()
		return export_snapshot(current)
	end

	function holder:update(mutator, opts)
		opts = opts or {}
		local next_ = clone_snapshot(current)
		mutator(next_)

		local changed = not same_snapshot(current, next_)
		if changed then
			current = next_
		end
		if opts.bump_pulse and changed then
			pulse:signal()
		end
		if opts.publish_force then
			maybe_publish(true)
		elseif opts.publish and changed then
			maybe_publish(false)
		end
		return changed
	end

	function holder:pulse()
		return pulse
	end

	function holder:changed_op(seen)
		return pulse:changed_op(seen):wrap(function(version)
			return version, export_snapshot(current)
		end)
	end

	function holder:unretain()
		state_conn:unretain(topic)
	end

	maybe_publish(true)
	return holder
end

local function send_required(tx, item)
	local ok, reason = tx:send(item)
	if ok ~= true then
		error('session control queue failed: ' .. tostring(reason or 'closed'), 0)
	end
end

local function same_summary(a, b)
	if a == nil or b == nil then return a == b end
	return a.state == b.state
		and a.ready == b.ready
		and a.established == b.established
		and a.generation == b.generation
end

local function next_session_ctl_event_op(state)
	local ops = {
		control = state.control_rx:recv_op(),
		status = state.status_rx:recv_op(),
	}

	local deadline = state.next_deadline()
	if deadline < math.huge then
		ops.timer = sleep.sleep_until_op(deadline):wrap(function()
			return true
		end)
	end

	return named_choice(ops)
end

function M.run(ctx)
	local control_rx = assert(ctx.control_rx, 'session_ctl requires control_rx')
	local tx_control = assert(ctx.tx_control, 'session_ctl requires tx_control')
	local status_rx = assert(ctx.status_rx, 'session_ctl requires status_rx')
	local session = assert(ctx.session, 'session_ctl requires session state')
	local state_conn = assert(ctx.state_conn, 'session_ctl requires state_conn')
	local report_tx = ctx.report_tx
	local hello_interval = tonumber(ctx.hello_interval_s) or 2.0
	local ping_interval = tonumber(ctx.ping_interval_s) or 10.0
	local liveness_timeout = tonumber(ctx.liveness_timeout_s) or 30.0
	local link_id = ctx.link_id
	local topic = statefmt.component_topic(link_id, 'session')

	local rpc_ready = false
	local next_hello_at = runtime.now()
	local next_ping_at = runtime.now() + ping_interval
	local last_summary = nil

	local function snapshot()
		return session:get()
	end

	local function maybe_report_summary(force)
		if not report_tx then return end

		local snap = snapshot()
		local summary = {
			state = snap.state,
			ready = snap.ready,
			established = snap.established,
			generation = snap.generation,
		}

		if force or not same_summary(summary, last_summary) then
			send_required(report_tx, {
				tag = 'link_summary',
				link_id = link_id,
				summary = summary,
			})
			last_summary = summary
		end
	end

	local function state_mut(mutator)
		local changed = session:update(mutator, { bump_pulse = true, publish = true })
		if changed then
			maybe_report_summary(false)
		end
		return changed
	end

	local function activity_mut(mutator)
		local changed = session:update(mutator, { publish = true })
		if changed then
			maybe_report_summary(false)
		end
		return changed
	end

	local function bump_generation(mutator)
		return state_mut(function(s)
			if mutator then mutator(s) end
			s.generation = s.generation + 1
		end)
	end

	local function refresh_ready()
		state_mut(function(s)
			s.ready = s.established and rpc_ready
		end)
	end

	local function send_control(frame)
		local item = assert(protocol.writer_item('control', frame))
		send_required(tx_control, item)
	end

	local function next_deadline()
		local snap = snapshot()
		local best = math.huge

		if not snap.established then
			if next_hello_at < best then best = next_hello_at end
		else
			if next_ping_at < best then best = next_ping_at end
			if snap.last_rx_at then
				local t = snap.last_rx_at + liveness_timeout
				if t < best then best = t end
			end
			if snap.last_pong_at then
				local t = snap.last_pong_at + liveness_timeout
				if t < best then best = t end
			end
		end

		return best
	end

	local state = {
		control_rx = control_rx,
		status_rx = status_rx,
		next_deadline = next_deadline,
	}

	maybe_report_summary(true)

	fibers.current_scope():finally(function()
		state_mut(function(s)
			s.down = true
			s.ready = false
			s.established = false
		end)
		state_conn:unretain(topic)
	end)

	while true do
		local which, item = perform(next_session_ctl_event_op(state))

		if which == 'control' and item then
			local msg = item.msg or item
			if msg.type == 'hello' or msg.type == 'hello_ack' then
				local prev = snapshot().peer_sid
				if prev ~= nil and prev ~= msg.sid then
					rpc_ready = false
					bump_generation(function(s)
						s.down = false
						s.peer_sid = msg.sid
						s.peer_node = msg.node
						s.established = true
						s.last_rx_at = item.at or runtime.now()
						s.ready = false
					end)
				else
					state_mut(function(s)
						s.down = false
						s.peer_sid = msg.sid
						s.peer_node = msg.node
						s.established = true
						s.last_rx_at = item.at or runtime.now()
					end)
				end

				if msg.type == 'hello' then
					send_control({
						type = 'hello_ack',
						sid = snapshot().local_sid,
						node = ctx.node_id or link_id,
					})
				end

				next_ping_at = runtime.now() + ping_interval
				refresh_ready()

			elseif msg.type == 'ping' then
				activity_mut(function(s)
					s.last_rx_at = item.at or runtime.now()
				end)
				send_control({ type = 'pong', sid = snapshot().local_sid })

			elseif msg.type == 'pong' then
				activity_mut(function(s)
					s.last_rx_at = item.at or runtime.now()
					s.last_pong_at = item.at or runtime.now()
				end)
			end

		elseif which == 'status' and item then
			if item.kind == 'rx_activity' then
				activity_mut(function(s)
					s.last_rx_at = item.at
				end)
			elseif item.kind == 'tx_activity' then
				activity_mut(function(s)
					s.last_tx_at = item.at
				end)
			elseif item.kind == 'rpc_ready' then
				rpc_ready = not not item.ready
				refresh_ready()
			end

		elseif which == 'timer' then
			local now = runtime.now()
			local snap = snapshot()

			if not snap.established then
				if now >= next_hello_at then
					send_control({
						type = 'hello',
						sid = snap.local_sid,
						node = ctx.node_id or ctx.link_id,
					})
					next_hello_at = now + hello_interval
				end
			else
				if now >= next_ping_at then
					send_control({ type = 'ping', sid = snap.local_sid })
					next_ping_at = now + ping_interval
				end
				if snap.last_rx_at and (now - snap.last_rx_at) > liveness_timeout then
					error('peer_liveness_timeout', 0)
				end
				if snap.last_pong_at and (now - snap.last_pong_at) > liveness_timeout then
					error('peer_pong_timeout', 0)
				end
			end
		end
	end
end

return M
