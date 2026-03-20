-- services/hal.lua
--
-- HAL façade (reactor + worker lanes).
--
-- Responsibilities
--   * Stable RPC surface: rpc/hal/*
--   * Structural apply lane:
--       - apply_net
--       - apply_wifi
--     These remain revision-driven and idempotent by req.rev.
--
--   * Sense lane:
--       - list_links
--       - probe_links
--       - read_link_counters
--     These are read-only runtime methods used by NET to build health/load state.
--
--   * Live lane:
--       - apply_link_shaping_live
--       - apply_multipath_live
--       - persist_multipath_state
--     These are runtime dataplane or persistence mutations. They are serialised
--     so tc / routing / targeted UCI writes do not interleave unpredictably.
--
-- Important boundary
--   HAL does not decide policy.
--   HAL only performs bounded OS-facing work and returns facts/results.

local fibers       = require 'fibers'
local mailbox      = require 'fibers.mailbox'
local safe         = require 'coxpcall'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local base         = require 'devicecode.service_base'

local M            = {}

local function t(...) return { ... } end

local function backend_name_from_env(opts)
	local v = os.getenv('DEVICECODE_HAL_BACKEND')
	if v and v ~= '' then return v end
	local env = opts and opts.env or (os.getenv('DEVICECODE_ENV') or 'dev')
	if env == 'prod' then return 'openwrt' end
	return 'hosttest'
end

local function safe_invoke(backend, method, arg1, msg)
	local fn = backend and backend[method]
	if type(fn) ~= 'function' then
		return { ok = false, err = 'unknown method: ' .. tostring(method) }
	end

	local ok, out = safe.pcall(function()
		return fn(backend, arg1, msg)
	end)

	if not ok then
		return { ok = false, err = tostring(out) }
	end

	if type(out) ~= 'table' then
		return { ok = false, err = 'backend returned non-table reply' }
	end

	if out.ok == nil then out.ok = true end
	return out
end

local function reply_best_effort(conn, msg, payload)
	if msg.reply_to == nil then
		return false, 'no_reply_to'
	end
	local ok, reason = conn:publish_one(msg.reply_to, payload, { id = msg.id })
	return ok, reason
end

local function try_enqueue(tx, job)
	local ev = tx:send_op(job)
	assert(ev and ev.try_fn, 'hal: expected mailbox send_op to expose try_fn')

	local ready, ok, reason = ev.try_fn()
	assert(ready, 'hal: internal mailbox send would block (unexpected)')

	if ok == true then return true, nil end
	if ok == nil then return false, 'closed' end
	return false, reason or 'full'
end

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'hal', env = opts.env })
	local name = svc.name

	svc:status('starting')
	svc:obs_log('info', { what = 'start_entered' })

	local rpc_root = t('rpc', 'hal')

	-- Select backend.
	local bname    = backend_name_from_env(opts)
	local mod      = require('services.hal.backends.' .. bname)

	local host     = {
		state_dir = os.getenv('DEVICECODE_STATE_DIR'),
		env       = os.getenv('DEVICECODE_ENV') or 'dev',

		-- Observability hooks exposed to the backend. These keep the backend free
		-- from direct knowledge of the bus topic layout.
		log       = function(level, payload) svc:obs_log(level, payload) end,
		event     = function(ev, payload) svc:obs_event(ev, payload) end,
		retain    = function(topic, payload) conn:retain(topic, payload) end,
		publish   = function(topic, payload) conn:publish(topic, payload) end,

		-- Time helpers for any backend code that needs timestamps.
		now       = function() return svc:now() end,
		wall      = function() return svc:wall() end,
	}

	local backend  = assert(mod.new(host), 'backend new() returned nil')
	local caps     = (backend.capabilities and backend:capabilities()) or {}

	-- Retained announce for discovery.
	conn:retain(t('svc', name, 'announce'), {
		role     = 'hal',
		rpc_root = rpc_root,
		backend  = (backend.name and backend:name()) or bname,
		caps     = caps,
	})

	svc:status('running', { rpc_root = 'rpc/hal', backend = bname })
	svc:obs_event('ready', { rpc_root = 'rpc/hal', backend = bname })
	svc:obs_log('info', { what = 'hal_started', backend = bname })

	-- Basic heartbeat.
	svc:spawn_heartbeat(30.0, 'tick')

	-- Method registry.
	--
	-- Kinds:
	--   rpc   : generic request/response, usually small or infrequent
	--   sense : runtime read/probe methods used by NET
	--   live  : runtime dataplane / persistence mutations
	--   apply : structural reconcile methods, serialised and rev-idempotent
	local methods = {
		-- Generic/state methods.
		read_state              = { kind = 'rpc' },
		write_state             = { kind = 'rpc' },
		dump                    = { kind = 'rpc' },

		-- Runtime sensing.
		list_links              = { kind = 'sense' },
		probe_links             = { kind = 'sense' },
		read_link_counters      = { kind = 'sense' },

		-- Structural apply.
		apply_net               = { kind = 'apply', domain = 'net' },
		apply_wifi              = { kind = 'apply', domain = 'wifi' },

		-- Runtime live apply.
		apply_link_shaping_live = { kind = 'live', domain = 'link_shaping_live' },
		apply_multipath_live    = { kind = 'live', domain = 'multipath_live' },
		persist_multipath_state = { kind = 'live', domain = 'multipath_persist' },
	}

	-- One endpoint per method.
	local endpoints = {}
	for method in pairs(methods) do
		endpoints[method] = conn:bind(t('rpc', 'hal', method), { queue_len = 16 })
	end

	-- Internal work queues.
	--
	-- These are deliberately bounded. The system should reject and retry rather
	-- than accumulate unbounded work under load.
	local rpc_tx,   rpc_rx   = mailbox.new(64, { full = 'reject_newest' })
	local sense_tx, sense_rx = mailbox.new(64, { full = 'reject_newest' })
	local live_tx,  live_rx  = mailbox.new(32, { full = 'reject_newest' })
	local apply_tx, apply_rx = mailbox.new(16, { full = 'reject_newest' })

	-- Generic RPC worker.
	fibers.spawn(function()
		while true do
			local job = perform(rpc_rx:recv_op())
			if job == nil then return end

			local method = job.method
			local msg    = job.msg
			local req    = msg.payload or {}

			svc:obs_event('rpc_in', { id = msg.id, method = method })

			local reply  = safe_invoke(backend, method, req, msg)
			local ok, reason = reply_best_effort(conn, msg, reply)

			svc:obs_event('rpc_out', {
				id     = msg.id,
				method = method,
				ok     = (ok == true),
				reason = reason,
			})
		end
	end)

	-- Sense worker.
	--
	-- This lane should only do reads/probes. It is kept separate so that probe
	-- traffic does not interfere with structural apply work.
	fibers.spawn(function()
		while true do
			local job = perform(sense_rx:recv_op())
			if job == nil then return end

			local method = job.method
			local msg    = job.msg
			local req    = msg.payload or {}

			svc:obs_event(method, { id = msg.id, phase = 'begin' })

			local reply = safe_invoke(backend, method, req, msg)
			if reply.applied == nil then reply.applied = true end
			if reply.changed == nil then reply.changed = false end

			local ok, reason = reply_best_effort(conn, msg, reply)

			svc:obs_event(method, {
				id      = msg.id,
				phase   = 'end',
				ok      = (reply.ok == true),
				applied = (reply.applied == true),
				changed = (reply.changed == true),
				reason  = reason,
				err     = (reply.ok ~= true) and tostring(reply.err or 'sense failed') or nil,
			})
		end
	end)

	-- Live worker.
	--
	-- This serialises runtime dataplane mutations. It is intentionally separate
	-- from the structural apply lane so NET can do frequent live adjustments
	-- without mixing them with full reconcile/reload flows.
	fibers.spawn(function()
		while true do
			local job = perform(live_rx:recv_op())
			if job == nil then return end

			local method = job.method
			local msg    = job.msg
			local req    = msg.payload or {}

			svc:obs_event(method, { id = msg.id, phase = 'begin' })

			local reply = safe_invoke(backend, method, req, msg)
			if reply.applied == nil then reply.applied = (reply.ok == true) end
			if reply.changed == nil then reply.changed = (reply.ok == true) end

			local ok, reason = reply_best_effort(conn, msg, reply)

			svc:obs_event(method, {
				id      = msg.id,
				phase   = 'end',
				ok      = (reply.ok == true),
				applied = (reply.applied == true),
				changed = (reply.changed == true),
				reason  = reason,
				err     = (reply.ok ~= true) and tostring(reply.err or 'live apply failed') or nil,
			})
		end
	end)

	-- Structural apply worker.
	--
	-- Revision-driven idempotency remains here. This worker serialises the
	-- disruptive, whole-domain operations.
	fibers.spawn(function()
		local last_rev = {} -- last_rev[domain] = integer

		while true do
			local job = perform(apply_rx:recv_op())
			if job == nil then return end

			local method  = job.method
			local msg     = job.msg
			local meta    = methods[method] or {}
			local domain  = meta.domain or method

			local req     = msg.payload or {}
			local desired = req.desired
			if desired == nil then desired = req end

			if type(desired) ~= 'table' then
				reply_best_effort(conn, msg, {
					ok      = false,
					err     = 'desired must be a table',
					applied = false,
					changed = false,
				})
			else
				local rev = req.rev
				if type(rev) == 'number' then rev = math.floor(rev) else rev = nil end

				svc:obs_event(method, { id = msg.id, gen = req.gen, rev = rev, phase = 'begin' })

				if rev ~= nil and last_rev[domain] ~= nil and rev <= last_rev[domain] then
					local reply = { ok = true, applied = true, changed = false }
					reply_best_effort(conn, msg, reply)
					svc:obs_event(method, {
						id      = msg.id,
						gen     = req.gen,
						rev     = rev,
						phase   = 'end',
						ok      = true,
						applied = true,
						changed = false,
					})
				else
					local reply = safe_invoke(backend, method, desired, msg)

					if reply.applied == nil then reply.applied = (reply.ok == true) end
					if reply.changed == nil then reply.changed = (reply.ok == true) end

					if reply.ok == true and reply.applied ~= false and rev ~= nil then
						last_rev[domain] = rev
					end

					reply_best_effort(conn, msg, reply)

					svc:obs_event(method, {
						id      = msg.id,
						gen     = req.gen,
						rev     = rev,
						phase   = 'end',
						ok      = (reply.ok == true),
						applied = (reply.applied == true),
						changed = (reply.changed == true),
						err     = (reply.ok ~= true) and tostring(reply.err or 'apply failed') or nil,
					})
				end
			end
		end
	end)

	-- Reactor.
	--
	-- This waits on all endpoints and routes each request into the appropriate
	-- internal lane without doing backend work inline.
	while true do
		local arms = {}
		for method, ep in pairs(endpoints) do
			arms[method] = ep:recv_op()
		end

		local which, msg, err = perform(named_choice(arms))
		if not msg then
			svc:obs_log('warn', { what = 'endpoint_closed', method = which, err = tostring(err) })
			return
		end

		local meta = methods[which]
		if not meta then
			fibers.spawn(function()
				reply_best_effort(conn, msg, { ok = false, err = 'unknown method' })
			end)
		else
			local job = { method = which, msg = msg }
			local okq, qerr

			if meta.kind == 'apply' then
				okq, qerr = try_enqueue(apply_tx, job)
			elseif meta.kind == 'live' then
				okq, qerr = try_enqueue(live_tx, job)
			elseif meta.kind == 'sense' then
				okq, qerr = try_enqueue(sense_tx, job)
			else
				okq, qerr = try_enqueue(rpc_tx, job)
			end

			if not okq then
				fibers.spawn(function()
					reply_best_effort(conn, msg, {
						ok     = false,
						err    = 'busy',
						detail = tostring(qerr),
					})
				end)
			end
		end
	end
end

return M
