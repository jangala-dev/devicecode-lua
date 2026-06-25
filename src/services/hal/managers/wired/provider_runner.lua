-- services/hal/managers/wired/provider_runner.lua
--
-- Owned runner for one HAL wired-provider backend. The runner is the sole
-- owner of the backend/session object: polling, snapshots and future controls
-- all pass through this mailbox, giving CML-style serialisation without locks.

local fibers = require 'fibers'
local safe = require 'coxpcall'
local op = require 'fibers.op'
local channel = require 'fibers.channel'
local sleep = require 'fibers.sleep'
local runtime = require 'fibers.runtime'
local tablex = require 'shared.table'

local M = {}
local Runner = {}
Runner.__index = Runner

local function max(a, b) if a > b then return a end return b end

local function copy(v) return tablex.deep_copy(v) end

local function stable_signature(v)
	local tv = type(v)
	if tv == 'nil' or tv == 'boolean' or tv == 'number' or tv == 'string' then
		return tv .. ':' .. tostring(v)
	end
	if tv ~= 'table' then return tv .. ':' .. tostring(v) end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local out = { 'table{' }
	for i = 1, #keys do
		local k = keys[i]
		out[#out + 1] = stable_signature(k)
		out[#out + 1] = '='
		out[#out + 1] = stable_signature(v[k])
		out[#out + 1] = ';'
	end
	out[#out + 1] = '}'
	return table.concat(out)
end

local function merge_table(dst, src)
	dst = dst or {}
	if type(src) ~= 'table' then return dst end
	for k, v in pairs(src) do
		if v ~= nil then
			if type(v) == 'table' and type(dst[k]) == 'table' then
				merge_table(dst[k], v)
			else
				dst[k] = copy(v)
			end
		end
	end
	return dst
end

local function merge_observation(cache, snapshot)
	cache = cache or {
		status = {},
		identity = {},
		runtime = {},
		power = {},
		surfaces = {},
		topology = {},
	}
	snapshot = snapshot or {}
	if type(snapshot.status) == 'table' then merge_table(cache.status, snapshot.status) end
	for _, key in ipairs({ 'identity', 'runtime', 'power', 'topology' }) do
		if type(snapshot[key]) == 'table' then merge_table(cache[key], snapshot[key]) end
	end
	if type(snapshot.surfaces) == 'table' then
		for surface_id, surface in pairs(snapshot.surfaces) do
			local id = tostring(surface_id or '')
			if id ~= '' and type(surface) == 'table' then
				cache.surfaces[id] = merge_table(cache.surfaces[id] or {}, surface)
			end
		end
	end
	return cache
end

local function emit_state_changed(self, key, payload)
	local sig = stable_signature(payload or {})
	if self.emitted[key] == sig then return true, nil, false end
	self.emitted[key] = sig
	local ok, err = self.emit_state(self.provider_id, key, payload or {})
	if ok == false or ok == nil then
		self.emitted[key] = nil
		return nil, err, false
	end
	return true, nil, true
end

local function emit_snapshot(self, snapshot, present)
	snapshot = snapshot or {}
	present = present or snapshot
	local ok, err
	if present.status ~= nil then
		ok, err = emit_state_changed(self, 'status', snapshot.status or { state = 'available', available = snapshot.ok == true })
		if ok ~= true then return nil, err end
	end
	if present.identity ~= nil then
		ok, err = emit_state_changed(self, 'identity', snapshot.identity or {})
		if ok == false or ok == nil then return nil, err end
	end
	if present.runtime ~= nil then
		ok, err = emit_state_changed(self, 'runtime', snapshot.runtime or {})
		if ok == false or ok == nil then return nil, err end
	end
	if present.power ~= nil then
		ok, err = emit_state_changed(self, 'power', snapshot.power or {})
		if ok == false or ok == nil then return nil, err end
	end
	if present.surfaces ~= nil then
		ok, err = emit_state_changed(self, 'surfaces', { surfaces = snapshot.surfaces or {} })
		if ok == false or ok == nil then return nil, err end
	end
	if present.topology ~= nil then
		ok, err = emit_state_changed(self, 'topology', snapshot.topology or {})
		if ok == false or ok == nil then return nil, err end
	end
	return true, nil
end

local function publish_observation(self, snapshot)
	self.observation = merge_observation(self.observation, snapshot)
	return emit_snapshot(self, self.observation, snapshot or {})
end

local function emit_status(self, status)
	local ok, err = emit_state_changed(self, 'status', status or { state = 'available', available = true })
	if ok == false or ok == nil then return nil, err end
	return true, nil
end

local function copy_list(list)
	local out = {}
	for i = 1, #(list or {}) do out[i] = list[i] end
	return out
end

local function append_unique(out, seen, value)
	value = tostring(value or '')
	if value ~= '' and not seen[value] then
		seen[value] = true
		out[#out + 1] = value
	end
end

local function perform_backend_method(backend, method, opts)
	local opname = tostring(method) .. '_op'
	local fn = backend and backend[opname]
	if type(fn) ~= 'function' then return { ok = false, err = 'wired backend missing ' .. opname } end
	local ok, backend_op = safe.pcall(function () return fn(backend, opts or {}) end)
	if not ok then return { ok = false, err = tostring(backend_op) } end
	if type(backend_op) ~= 'table' then return { ok = false, err = opname .. ' did not return an Op' } end
	local ok2, result = safe.pcall(function () return fibers.perform(backend_op) end)
	if not ok2 then return { ok = false, err = tostring(result) } end
	if type(result) == 'table' then return result end
	return { ok = result == true, result = result }
end

local function failure_status(provider_id, groups, result)
	local gs = groups or {}
	local err = result and result.err or (result and result.status and result.status.err) or 'wired provider observation failed'
	local unavailable = false
	for _, group in ipairs(gs) do
		if group == 'panel' or group == 'snapshot' then unavailable = true end
	end
	if #gs == 0 then unavailable = true end
	return {
		state = unavailable and 'unavailable' or 'degraded',
		available = not unavailable,
		err = err,
		groups = copy_list(gs),
		provider_id = provider_id,
		polling = true,
	}
end

local function groups_for_plans(plans)
	local groups, seen = {}, {}
	for _, plan in ipairs(plans or {}) do
		for _, group in ipairs(plan.groups or {}) do append_unique(groups, seen, group) end
	end
	return groups
end

local function initialise_due_times(self)
	local now = runtime.now()
	for i, plan in ipairs(self.poll_plan or {}) do
		self.next_due[plan.name] = now + math.min(1.0, (i - 1) * 0.25)
	end
end

local function next_due_time(self)
	local due = nil
	for _, plan in ipairs(self.poll_plan or {}) do
		local t = self.next_due[plan.name]
		if t ~= nil and (due == nil or t < due) then due = t end
	end
	if due == nil then due = runtime.now() + 3600 end
	return max(due, self.idle_until or 0)
end

local function due_plans(self, now)
	local plans = {}
	for _, plan in ipairs(self.poll_plan or {}) do
		local t = self.next_due[plan.name]
		if t ~= nil and t <= now then plans[#plans + 1] = plan end
	end
	return plans
end

local function mark_plans_attempted(self, plans)
	local now = runtime.now()
	for _, plan in ipairs(plans or {}) do self.next_due[plan.name] = now + plan.interval_s end
	self.idle_until = now + self.min_idle_s
end

local function runner_request_op(self, verb, opts)
	return op.guard(function ()
		if self.closed then return op.always({ ok = false, err = 'wired provider runner closed', code = 'closed' }) end
		local reply_ch = channel.new(1)
		local msg = { kind = 'request', verb = verb, opts = opts or {}, reply_ch = reply_ch }
		return fibers.run_scope_op(function ()
			fibers.perform(self.request_ch:put_op(msg))
			return fibers.perform(reply_ch:get_op())
		end):wrap(function (status, _report, result_or_primary, err)
			if status == 'ok' then return result_or_primary, err end
			return { ok = false, err = tostring(result_or_primary or status or 'wired provider request failed') }, nil
		end)
	end)
end

function Runner:snapshot_op(req) return runner_request_op(self, 'snapshot', req) end
function Runner:watch_op(req) return runner_request_op(self, 'snapshot', req) end
function Runner:observe_groups_op(req) return runner_request_op(self, 'observe_groups', req) end
function Runner:apply_attachments_op(req) return runner_request_op(self, 'apply_attachments', req) end
function Runner:set_poe_op(req) return runner_request_op(self, 'set_poe', req) end
function Runner:bounce_op(req) return runner_request_op(self, 'bounce', req) end

function Runner:terminate(reason)
	self.closed = true
	if self.scope then local scope = self.scope; self.scope = nil; scope:cancel(reason or 'wired provider runner terminated') end
	if self.backend and type(self.backend.terminate) == 'function' then self.backend:terminate(reason or 'wired provider runner terminated') end
	return true, nil
end

function Runner:emit_observing()
	if self.observing_emitted then return true, nil end
	local ok, err = emit_status(self, {
		state = 'observing',
		available = false,
		driver = self.provider_name,
		polling = true,
	})
	if ok == true then self.observing_emitted = true end
	return ok, err
end

function Runner:poll_due()
	local now = runtime.now()
	local plans = due_plans(self, now)
	if #plans == 0 then return true, nil end
	local groups = groups_for_plans(plans)
	local result = perform_backend_method(self.backend, 'observe_groups', { groups = groups })
	mark_plans_attempted(self, plans)
	if result and result.ok == true then return publish_observation(self, result) end
	return emit_status(self, failure_status(self.provider_id, groups, result))
end

function Runner:handle_request(msg)
	if type(msg) ~= 'table' then return end
	local verb = msg.verb
	local opts = msg.opts or {}
	local result
	if verb == 'snapshot' or verb == 'watch' then
		result = perform_backend_method(self.backend, 'snapshot', opts)
		if result and result.ok == true then publish_observation(self, result) end
	elseif verb == 'observe_groups' then
		result = perform_backend_method(self.backend, 'observe_groups', opts)
		if result and result.ok == true then publish_observation(self, result) end
	elseif verb == 'apply_attachments' or verb == 'set_poe' or verb == 'bounce' then
		result = perform_backend_method(self.backend, verb, opts)
	else
		result = { ok = false, err = 'unsupported wired-provider verb: ' .. tostring(verb) }
	end
	if msg.reply_ch then fibers.perform(msg.reply_ch:put_op(result)) end
end

function Runner:run()
	if self.ready_cond ~= nil then fibers.perform(self.ready_cond:wait_op()) end
	if self.closed then return end
	local ok, err = self:emit_observing()
	if ok ~= true then self.log('error', { what = 'wired_provider_initial_status_emit_failed', provider = self.provider_id, err = err }) end
	initialise_due_times(self)
	while not self.closed do
		local which, msg = fibers.perform(op.named_choice({
			request = self.request_ch:get_op(),
			due = sleep.sleep_until_op(next_due_time(self)),
		}))
		if which == 'request' then
			self:handle_request(msg)
		elseif which == 'due' then
			local pok, perr = self:poll_due()
			if pok ~= true then self.log('error', { what = 'wired_provider_poll_emit_failed', provider = self.provider_id, err = perr }) end
		end
	end
end

function Runner:start()
	local ok, err = self.scope:spawn(function () self:run() end)
	if not ok then
		self:terminate(tostring(err or 'wired provider runner spawn failed'))
		return nil, err or 'wired provider runner spawn failed'
	end
	return true, nil
end

function M.new(opts)
	opts = opts or {}
	if type(opts.provider_id) ~= 'string' or opts.provider_id == '' then return nil, 'provider_id is required' end
	if type(opts.provider_name) ~= 'string' or opts.provider_name == '' then return nil, 'provider_name is required' end
	if type(opts.backend) ~= 'table' then return nil, 'backend is required' end
	if type(opts.poll_plan) ~= 'table' then return nil, 'poll_plan is required' end
	if type(opts.parent_scope) ~= 'table' then return nil, 'parent_scope is required' end
	if type(opts.emit_state) ~= 'function' then return nil, 'emit_state callback is required' end

	local child, err = opts.parent_scope:child()
	if not child then return nil, err or 'wired provider runner scope create failed' end
	local self = setmetatable({
		provider_id = opts.provider_id,
		provider_name = opts.provider_name,
		backend = opts.backend,
		poll_plan = opts.poll_plan,
		ready_cond = opts.ready_cond,
		emit_state = opts.emit_state,
		observation = nil,
		emitted = {},
		log = opts.log or function () end,
		request_ch = channel.new(opts.request_queue_size or 32),
		scope = child,
		closed = false,
		next_due = {},
		idle_until = 0,
		min_idle_s = tonumber(opts.min_idle_s) or 0.05,
		observing_emitted = false,
	}, Runner)
	return self, nil
end

M._test = {
	groups_for_plans = groups_for_plans,
}

return M
