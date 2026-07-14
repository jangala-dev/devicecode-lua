-- services/update/component_watch.lua
--
-- Service-owned watch of Device's canonical component projections.  This feeds
-- Update's reconciliation observer without letting active jobs perform ad-hoc
-- bus watches.

local fibers       = require 'fibers'
local scoped_work  = require 'devicecode.support.scoped_work'
local bus_cleanup  = require 'devicecode.support.bus_cleanup'
local topics       = require 'services.update.topics'
local queue        = require 'devicecode.support.queue'

local M = {}

local function component_list(config, explicit)
	local seen, out = {}, {}
	local function add(c)
		if type(c) == 'string' and c ~= '' and not seen[c] then
			seen[c] = true
			out[#out + 1] = c
		end
	end
	for _, c in ipairs(explicit or {}) do add(c) end
	for c in pairs((config and config.components) or {}) do add(c) end
	if #out == 0 then add('mcu') end
	table.sort(out)
	return out
end

local function open_watches(scope, conn, components, queue_len)
	local watches = {}
	for _, component in ipairs(components) do
		local watch, err = bus_cleanup.watch_retained(conn, topics.device_component(component), {
			queue_len = queue_len or 16,
			replay = true,
		})
		if not watch then
			for _, w in pairs(watches) do bus_cleanup.unwatch_retained(conn, w) end
			return nil, err
		end
		watches[component] = watch
	end
	scope:finally(function ()
		for _, w in pairs(watches) do bus_cleanup.unwatch_retained(conn, w) end
	end)
	return watches, nil
end

local function report_component_fact(params, component, ev)
	if not params.events_tx then
		return true, nil
	end
	return queue.try_admit_required(params.events_tx, {
		kind = 'component_fact_changed',
		component = component,
		payload = ev.payload,
		origin = ev.origin,
	}, 'update_component_fact_changed_admission_failed')
end

local function watch_loop(scope, params)
	local observer = assert(params.observer, 'component_watch observer required')
	local conn = assert(params.conn, 'component_watch conn required')
	local watches, err = open_watches(scope, conn, params.components, params.queue_len)
	if not watches then error(err or 'component_watch_open_failed', 0) end

	while true do
		local arms = {}
		for component, watch in pairs(watches) do
			arms[component] = watch:recv_op():wrap(function (ev, recv_err)
				return component, ev, recv_err
			end)
		end
		local _, component, ev, recv_err = fibers.perform(fibers.named_choice(arms))
		if ev == nil then
			return { role = 'update_component_watch', reason = recv_err or 'component_watch_closed' }
		end
		if ev.op == 'retain' or ev.event == 'retain' or ev.type == 'retain' or ev.kind == 'retain' then
			local ok_update, update_err = observer:update_component(component, ev.payload, ev.origin)
			if ok_update == nil then error(update_err or 'component_observer_update_failed', 0) end
			report_component_fact(params, component, ev)
		elseif ev.op == 'unretain' or ev.event == 'unretain' or ev.type == 'unretain' or ev.kind == 'unretain' then
			observer:remove_component(component, 'component_unretained')
		end
	end
end

function M.start(scope, params)
	params = params or {}
	local components = component_list(params.config, params.components)
	return scoped_work.start {
		lifetime_scope = scope,
		reaper_scope   = scope,
		report_scope   = scope,
		identity = {
			kind = 'component_done',
			service_id = params.service_id or 'update',
			component = 'component_watch',
		},
		run = function (work_scope)
			return watch_loop(work_scope, {
				conn = params.conn,
				observer = params.observer,
				components = components,
				queue_len = params.queue_len,
				events_tx = params.events_tx,
			})
		end,
		report = params.report,
	}
end

return M
