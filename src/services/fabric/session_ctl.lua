-- services/fabric/session_ctl.lua
--
-- Owns the retained session subtree for one link:
--   state/fabric/link/<id>/session

local fibers    = require 'fibers'
local pulse_mod = require 'fibers.pulse'
local runtime   = require 'fibers.runtime'
local sleep     = require 'fibers.sleep'
local uuid      = require 'uuid'

local statefmt  = require 'services.fabric.statefmt'

local M = {}

local function clone_snapshot(s)
	return {
		state = s.state,
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

local function same_snapshot(a, b)
	if a == nil or b == nil then return a == b end
	return a.state == b.state
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

local function retain_best_effort(conn, topic, payload)
	if not conn then return end
	pcall(function ()
		conn:retain(topic, payload)
	end)
end

local function unretain_best_effort(conn, topic)
	if not conn then return end
	pcall(function ()
		conn:unretain(topic)
	end)
end

local function publish_state(conn, topic, link_id, snapshot)
	retain_best_effort(conn, topic, statefmt.link_component('session', link_id, {
		state = snapshot.state,
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
		state = 'opening',
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
		return current
	end

	function holder:update(mutator, opts)
		opts = opts or {}
		local next = clone_snapshot(current)
		mutator(next)

		local changed = not same_snapshot(current, next)
		if changed then
			current = next
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

	function holder:unretain()
		unretain_best_effort(state_conn, topic)
	end

	maybe_publish(true)
	return holder
end

local function required_send(tx, item)
	local ok, reason = tx:send(item)
	if ok ~= true then
		error('session control queue failed: ' .. tostring(reason or 'closed'), 0)
	end
end

function M.run(ctx)
	local control_rx = assert(ctx.control_rx, 'session_ctl requires control_rx')
	local tx_control = assert(ctx.tx_control, 'session_ctl requires tx_control')
	local status_rx = assert(ctx.status_rx, 'session_ctl requires status_rx')
	local session = assert(ctx.session, 'session_ctl requires session state')
	local state_conn = assert(ctx.state_conn, 'session_ctl requires state_conn')
	local hello_interval = tonumber(ctx.hello_interval_s) or 2.0
	local ping_interval = tonumber(ctx.ping_interval_s) or 10.0
	local liveness_timeout = tonumber(ctx.liveness_timeout_s) or 30.0
	local link_id = ctx.link_id
	local topic = statefmt.component_topic(link_id, 'session')

	local rpc_ready = false
	local next_hello_at = runtime.now()
	local next_ping_at = runtime.now() + ping_interval

	local function snapshot()
		return session:get()
	end

	local function state_mut(f)
		session:update(f, { bump_pulse = true, publish = true })
	end

	local function activity_mut(f)
		session:update(f, { publish = true })
	end

	local function bump_generation(mut)
		state_mut(function(s)
			if mut then mut(s) end
			s.generation = s.generation + 1
		end)
	end

	local function refresh_ready()
		local snap = snapshot()
		local ready = snap.established and rpc_ready
		state_mut(function(s)
			s.ready = ready
			if s.state ~= 'down' then
				if ready then
					s.state = 'ready'
				else
					s.state = 'establishing'
				end
			end
		end)
	end

	local function send_control(frame)
		local item = assert(require('services.fabric.protocol').writer_item('control', frame))
		required_send(tx_control, item)
	end

	state_mut(function(s)
		s.state = 'establishing'
	end)

	fibers.current_scope():finally(function()
		state_mut(function(s)
			s.state = 'down'
			s.ready = false
			s.established = false
		end)
		unretain_best_effort(state_conn, topic)
	end)

	while true do
		local snap = snapshot()
		local now = runtime.now()
		if not snap.established then
			if now >= next_hello_at then
				send_control({ type = 'hello', sid = snap.local_sid, node = ctx.node_id or ctx.link_id })
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

		local which, item = fibers.perform(fibers.named_choice({
			control = control_rx:recv_op(),
			status = status_rx:recv_op(),
			timer = sleep.sleep_op(0.5):wrap(function() return { kind = 'tick' } end),
		}))

		if which == 'control' and item then
			local msg = item.msg or item
			if msg.type == 'hello' or msg.type == 'hello_ack' then
				local prev = snap.peer_sid
				if prev ~= nil and prev ~= msg.sid then
					rpc_ready = false
					bump_generation(function(s)
						s.peer_sid = msg.sid
						s.peer_node = msg.node
						s.established = true
						s.last_rx_at = item.at or runtime.now()
						s.ready = false
					end)
				else
					state_mut(function(s)
						s.peer_sid = msg.sid
						s.peer_node = msg.node
						s.established = true
						s.last_rx_at = item.at or runtime.now()
					end)
				end
				if msg.type == 'hello' then
					send_control({ type = 'hello_ack', sid = snapshot().local_sid, node = ctx.node_id or link_id })
				end
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
				activity_mut(function(s) s.last_rx_at = item.at end)
			elseif item.kind == 'tx_activity' then
				activity_mut(function(s) s.last_tx_at = item.at end)
			elseif item.kind == 'rpc_ready' then
				rpc_ready = not not item.ready
				refresh_ready()
			end
		elseif which == 'timer' then
			-- tick only.
		end
	end
end

return M
