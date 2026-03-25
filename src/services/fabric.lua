-- services/fabric.lua
--
-- First-pass fabric service.
--
-- Responsibilities:
--   * wait for HAL
--   * consume retained config/fabric
--   * spawn one child scope per configured link
--   * restart sessions on config change
--
-- Required opts:
--   * connect(principal) -> bus connection

local fibers = require 'fibers'
local base   = require 'devicecode.service_base'

local config_mod = require 'services.fabric.config'
local session    = require 'services.fabric.session'

local M = {}

local function stop_children(children)
	for _, rec in pairs(children) do
		if rec and rec.scope then
			rec.scope:cancel('fabric reconfigure')
		end
	end
end

function M.start(conn, opts)
	opts = opts or {}
	if type(opts.connect) ~= 'function' then
		error('fabric: opts.connect(principal) is required', 2)
	end

	local svc = base.new(conn, { name = opts.name or 'fabric', env = opts.env })

	svc:status('starting')
	svc:obs_log('info', { what = 'start_entered' })

	local hal_announce, herr = svc:wait_for_hal({
		timeout = 60,
		tick    = 10,
	})
	if not hal_announce then
		local err = herr or 'no hal available'
		svc:status('failed', { reason = err })
		error(('fabric: failed to discover HAL: %s'):format(tostring(err)), 0)
	end

	conn:retain({ 'svc', svc.name, 'announce' }, {
		role = 'fabric',
		caps = {
			pub_proxy   = true,
			call_proxy  = true,
			uart_stream = true,
		},
	})

	local root = fibers.current_scope()
	local children = {}
	local current_gen = 0

	local function apply_config(cfg)
		current_gen = current_gen + 1
		local gen = current_gen

		stop_children(children)
		children = {}

		for link_id, link_cfg in pairs(cfg.links) do
			local child, cerr = root:child()
			if not child then
				svc:obs_log('error', {
					what    = 'link_child_failed',
					link_id = link_id,
					err     = tostring(cerr),
				})
			else
				local ok_spawn, serr = child:spawn(function()
					return session.run(conn, svc, {
						gen      = gen,
						link_id  = link_id,
						link     = link_cfg,
						connect  = opts.connect,
					})
				end)

				if not ok_spawn then
					child:cancel('spawn failed')
					svc:obs_log('error', {
						what    = 'link_spawn_failed',
						link_id = link_id,
						err     = tostring(serr),
					})
				else
					children[link_id] = {
						scope = child,
						cfg   = link_cfg,
					}
				end
			end
		end

		svc:status('running', {
			links = cfg.link_count,
			gen   = gen,
		})
		svc:obs_event('config_applied', {
			gen   = gen,
			links = cfg.link_count,
		})
		conn:retain({ 'state', 'fabric', 'main' }, {
			status = 'running',
			gen    = gen,
			links  = cfg.link_count,
			t      = svc:now(),
		})
	end

	local sub_cfg = conn:subscribe({ 'config', 'fabric' }, {
		queue_len = 4,
		full      = 'drop_oldest',
	})

	svc:spawn_heartbeat(30.0, 'tick')

	svc:status('waiting_config')
	svc:obs_log('info', { what = 'waiting_for_config' })

	while true do
		local msg, err = fibers.perform(sub_cfg:recv_op())
		if not msg then
			svc:status('failed', { reason = err })
			error(('fabric: config subscription ended: %s'):format(tostring(err)), 0)
		end

		local cfg, cerr = config_mod.normalise(msg.payload)
		if not cfg then
			svc:obs_log('warn', {
				what = 'bad_config',
				err  = tostring(cerr),
			})
		else
			apply_config(cfg)
		end
	end
end

return M
