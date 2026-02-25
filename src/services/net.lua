-- services/net.lua
--
-- Net service (single-fibre reactor), revision-driven:
--   * waits for HAL announce (retained)
--   * subscribes to retained config/net (payload: {rev=int, data=table})
--   * coalesces bursts and calls rpc/hal/apply_net with req.rev

local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local base = require 'devicecode.service_base'

local M = {}

local function now() return runtime.now() end

local function compile_desired_from_config(cfg)
	-- Placeholder: treat cfg as already-normalised desired state.
	return cfg
end

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'net', env = opts.env })

	svc:status('starting')
	svc:obs_log('info', { what = 'start_entered' })

	-- Ensure HAL is present (we do not need rpc_root; HAL RPC topics are fixed).
	local hal_announce, herr = svc:wait_for_hal({ timeout = 60, tick = 10 })
	if not hal_announce then
		svc:status('stopped', { reason = herr })
		svc:obs_log('error', { what = 'start_failed', err = tostring(herr) })
		return
	end

	svc:status('running', { hal_backend = hal_announce.backend })
	svc:obs_event('ready', { hal_backend = hal_announce.backend })

	-- Subscribe to retained config/net.
	svc:obs_log('info', 'waiting for initial config/net')
	local sub_cfg = conn:subscribe({ 'config', 'net' }, { queue_len = 10, full = 'drop_oldest' })

	local cfg = nil
	local cfg_rev = 0

	local dirty = false
	local next_apply_at = 1 / 0
	local debounce_s = 0.25

	local gen = 0

	local retry_s = 1.0
	local retry_max_s = 30.0

	local function mark_dirty(reason)
		dirty = true
		next_apply_at = now() + debounce_s
		svc:obs_event('dirty', { ts = svc:now(), at = svc:wall(), reason = reason, rev = cfg_rev })
	end

	-- Wait for first retained config.
	while cfg == nil do
		local msg, err = perform(sub_cfg:recv_op())
		if not msg then
			svc:status('stopped', { reason = err })
			svc:obs_log('warn', { what = 'config_subscription_ended', err = tostring(err) })
			return
		end

		local p = msg.payload
		if type(p) == 'table' and type(p.rev) == 'number' and type(p.data) == 'table' then
			cfg = p.data
			cfg_rev = math.floor(p.rev)
			svc:obs_event('config_update', { ts = svc:now(), at = svc:wall(), rev = cfg_rev })
			mark_dirty('config_update')
		else
			svc:obs_log('warn', { what = 'bad_config_payload', kind = type(p) })
		end
	end

	while true do
		local arms = { cfg = sub_cfg:recv_op() }
		if dirty then
			local dt = next_apply_at - now()
			if dt < 0 then dt = 0 end
			arms.timer = sleep.sleep_op(dt):wrap(function() return true end)
		end

		local which, a, b = perform(named_choice(arms))

		if which == 'cfg' then
			local msg, err = a, b
			if not msg then
				svc:status('stopped', { reason = err })
				svc:obs_log('warn', { what = 'config_subscription_ended', err = tostring(err) })
				return
			end

			local p = msg.payload
			if type(p) == 'table' and type(p.rev) == 'number' and type(p.data) == 'table' then
				local rev = math.floor(p.rev)
				if rev > cfg_rev then
					cfg = p.data
					cfg_rev = rev
					svc:obs_event('config_update', { ts = svc:now(), at = svc:wall(), rev = cfg_rev })
					mark_dirty('config_update')
				end
			else
				svc:obs_log('warn', { what = 'bad_config_payload', kind = type(p) })
			end
		else
			if dirty and now() >= next_apply_at then
				gen = gen + 1
				svc:obs_event('apply_begin', { gen = gen, rev = cfg_rev })

				local desired = compile_desired_from_config(cfg)

				local reply, call_err = svc:hal_call('apply_net', {
					gen     = gen,
					rev     = cfg_rev,
					desired = desired,
				}, 10.0)

				if not reply then
					svc:obs_log('warn', { what = 'apply_call_failed', err = tostring(call_err), gen = gen, rev = cfg_rev })
					next_apply_at = now() + retry_s
					retry_s = math.min(retry_s * 2, retry_max_s)
				else
					local ok = (reply.ok == true)
					local applied = (reply.applied == true)
					local changed = (reply.changed == true) or (reply.changed == nil and applied)

					svc:obs_event('apply_end', {
						gen     = gen,
						rev     = cfg_rev,
						applied = applied,
						changed = changed,
						ok      = ok,
						err     = (not ok) and tostring(reply.err or 'apply failed') or nil,
					})

					if ok then
						dirty = false
						next_apply_at = 1 / 0
						retry_s = 1.0
						svc:status('running', { last_applied_rev = cfg_rev, last_applied_gen = gen })
					else
						next_apply_at = now() + retry_s
						retry_s = math.min(retry_s * 2, retry_max_s)
					end
				end
			end
		end
	end
end

return M
