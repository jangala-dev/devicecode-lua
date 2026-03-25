-- services/hal.lua
--
-- HAL facade (reactor + worker lanes).

local fibers       = require 'fibers'
local mailbox      = require 'fibers.mailbox'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local base         = require 'devicecode.service_base'
local methods_mod  = require 'services.hal.methods'
local util         = require 'services.hal.util'
local hal_config   = require 'services.hal.config'

local M            = {}

local function t(...) return { ... } end

local function backend_name_from_env(opts)
	local v = os.getenv('DEVICECODE_HAL_BACKEND')
	if v and v ~= '' then return v end
	local env = opts and opts.env or (os.getenv('DEVICECODE_ENV') or 'dev')
	if env == 'prod' then return 'openwrt' end
	return 'hosttest'
end

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'hal', env = opts.env })
	local name = svc.name

	svc:status('starting')
	svc:obs_log('info', { what = 'start_entered' })

	local rpc_root = t('rpc', 'hal')

	local current_hal_config = {
		serial = {},
	}

	-- Select backend.
	local bname    = backend_name_from_env(opts)
	local mod      = require('services.hal.backends.' .. bname)

	local host     = {
		state_dir = os.getenv('DEVICECODE_STATE_DIR'),
		env       = os.getenv('DEVICECODE_ENV') or 'dev',

		log       = function(level, payload) svc:obs_log(level, payload) end,
		event     = function(ev, payload) svc:obs_event(ev, payload) end,
		retain    = function(topic, payload) conn:retain(topic, payload) end,
		publish   = function(topic, payload) conn:publish(topic, payload) end,

		now       = function() return svc:now() end,
		wall      = function() return svc:wall() end,
		get_hal_config = function()
			return current_hal_config
		end,
	}

	local backend  = assert(mod.new(host), 'backend new() returned nil')
	local caps     = (backend.capabilities and backend:capabilities()) or {}
	local methods  = methods_mod.registry()

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

	svc:spawn_heartbeat(30.0, 'tick')

	-- Subscribe to HAL-owned configuration.
	local sub_cfg = conn:subscribe({ 'config', 'hal' }, { queue_len = 4, full = 'drop_oldest' })

	fibers.spawn(function()
		while true do
			local msg, err = perform(sub_cfg:recv_op())
			if not msg then
				svc:obs_log('warn', { what = 'config_subscription_ended', err = tostring(err) })
				return
			end

			local cfg, cerr = hal_config.normalise(msg.payload)
			if not cfg then
				svc:obs_log('warn', {
					what = 'bad_hal_config',
					err  = tostring(cerr),
				})
			else
				current_hal_config = cfg
				svc:obs_event('config_update', {
					serial_refs = (function()
						local n = 0
						for _ in pairs(cfg.serial or {}) do n = n + 1 end
						return n
					end)(),
				})
			end
		end
	end)

	local endpoints = methods_mod.bind_endpoints(conn, methods, function(method)
		return t('rpc', 'hal', method)
	end, caps)

	-- Internal work queues.
	local rpc_tx,   rpc_rx   = mailbox.new(64, { full = 'reject_newest' })
	local sense_tx, sense_rx = mailbox.new(64, { full = 'reject_newest' })
	local live_tx,  live_rx  = mailbox.new(32, { full = 'reject_newest' })
	local apply_tx, apply_rx = mailbox.new(16, { full = 'reject_newest' })

	local queues = {
		rpc_tx   = rpc_tx,
		sense_tx = sense_tx,
		live_tx  = live_tx,
		apply_tx = apply_tx,
	}

	-- Generic RPC worker.
	fibers.spawn(function()
		while true do
			local job = perform(rpc_rx:recv_op())
			if job == nil then return end

			local method = job.method
			local msg    = job.msg
			local req    = msg.payload or {}

			svc:obs_event('rpc_in', { id = msg.id, method = method })

			local reply  = util.safe_invoke(backend, method, req, msg)
			local ok, reason = util.reply_best_effort(conn, msg, reply)

			svc:obs_event('rpc_out', {
				id     = msg.id,
				method = method,
				ok     = (ok == true),
				reason = reason,
			})
		end
	end)

	-- Sense worker.
	fibers.spawn(function()
		while true do
			local job = perform(sense_rx:recv_op())
			if job == nil then return end

			local method = job.method
			local msg    = job.msg
			local req    = msg.payload or {}

			svc:obs_event(method, { id = msg.id, phase = 'begin' })

			local reply = util.safe_invoke(backend, method, req, msg)
			if reply.applied == nil then reply.applied = true end
			if reply.changed == nil then reply.changed = false end

			local ok, reason = util.reply_best_effort(conn, msg, reply)

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
	fibers.spawn(function()
		while true do
			local job = perform(live_rx:recv_op())
			if job == nil then return end

			local method = job.method
			local msg    = job.msg
			local req    = msg.payload or {}

			svc:obs_event(method, { id = msg.id, phase = 'begin' })

			local reply = util.safe_invoke(backend, method, req, msg)
			if reply.applied == nil then reply.applied = (reply.ok == true) end
			if reply.changed == nil then reply.changed = (reply.ok == true) end

			local ok, reason = util.reply_best_effort(conn, msg, reply)

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
				util.reply_best_effort(conn, msg, {
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
					util.reply_best_effort(conn, msg, reply)
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
					local reply = util.safe_invoke(backend, method, desired, msg)

					if reply.applied == nil then reply.applied = (reply.ok == true) end
					if reply.changed == nil then reply.changed = (reply.ok == true) end

					if reply.ok == true and reply.applied ~= false and rev ~= nil then
						last_rev[domain] = rev
					end

					util.reply_best_effort(conn, msg, reply)

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

		local okq, qerr = methods_mod.enqueue_job(methods, which, queues, {
			method = which,
			msg    = msg,
		})

		if not okq then
			fibers.spawn(function()
				util.reply_best_effort(conn, msg, {
					ok     = false,
					err    = 'busy',
					detail = tostring(qerr),
				})
			end)
		end
	end
end

return M
