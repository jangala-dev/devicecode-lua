-- services/http/backend.lua
-- Named backend component owner for the HTTP service.
--
-- The real backend pump is long-running service work with its own identity and
-- completion.  It is represented through devicecode.support.scoped_work so that
-- backend failure/termination is reported as ordinary data to the HTTP
-- coordinator.  The small start()-only path is retained only for simple unit
-- fakes that have no pump to reap; production drivers should expose run() and
-- terminate().

local scoped_work = require 'devicecode.support.scoped_work'

local M = {}

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

function M.start(spec)
	if type(spec) ~= 'table' then return nil, 'invalid_args' end
	local lifetime_scope = spec.lifetime_scope
	local driver = spec.driver
	local events_port = spec.events_port
	if events_port ~= nil and (type(events_port) ~= 'table' or type(events_port.emit_required) ~= 'function') then
		return nil, 'events_port_required'
	end
	local function emit(ev, label)
		if not events_port then return true, nil end
		return events_port:emit_required(ev, label or 'http_backend_event_report_failed')
	end
	if not lifetime_scope or type(lifetime_scope.spawn) ~= 'function' then return nil, 'lifetime_scope_required' end
	if not driver then return nil, 'driver_required' end

	local identity = copy(spec.identity or {})
	identity.kind = identity.kind or 'backend_done'
	identity.component = identity.component or 'backend'
	identity.component_id = identity.component_id or 'http_backend'
	identity.generation = identity.generation or spec.generation or 1

	local component = {
		driver = driver,
		scope = nil,
		closed = false,
		_work = nil,
		_identity = identity,
	}

	function component:terminate(reason)
		local why = reason or 'backend_terminated'
		if self.closed then return true end
		self.closed = true
		if self._work and type(self._work.cancel) == 'function' then self._work:cancel(why) end
		if self.scope and type(self.scope.cancel) == 'function' then self.scope:cancel(why) end
		if driver and type(driver.terminate) == 'function' then driver:terminate(why) end
		return true
	end

	function component:identity()
		return copy(self._identity)
	end

	function component:outcome_op()
		if self._work and type(self._work.outcome_op) == 'function' then return self._work:outcome_op() end
		return nil, 'backend_has_no_outcome_op'
	end

	function component:outcome()
		if self._work and type(self._work.outcome) == 'function' then return self._work:outcome() end
		return nil
	end

	-- Preferred path: the backend pump is named scoped work.  The worker owns the
	-- driver pump and installs immediate termination as its finaliser.  The
	-- coordinator observes the stored completion through a reporter event.
	if type(driver.run) == 'function' then
		local handle, err = scoped_work.start({
			lifetime_scope = lifetime_scope,
			reaper_scope = lifetime_scope,
			report_scope = lifetime_scope,
			identity = identity,
			run = function (scope)
				component.scope = scope
				scope:finally(function (_, status, primary)
					if type(driver.terminate) == 'function' then
						driver:terminate(primary or status or 'backend_scope_finalised')
					end
				end)

				local ok, run_err = driver:run()
				if ok == nil or ok == false then error(run_err or 'backend_failed', 0) end
				return { reason = 'backend_run_returned' }
			end,
			report = function (ev)
				return emit(ev, 'http_backend_done_report_failed')
			end,
		})
		if not handle then return nil, err or 'backend_start_failed' end
		component._work = handle
		emit({ kind = 'backend_ready', component = 'backend', component_id = identity.component_id, generation = identity.generation }, 'http_backend_ready_report_failed')
		return component, nil
	end

	-- Compatibility path for simple unit fakes.  There is no pump, and therefore
	-- no meaningful backend completion to reap.  This is deliberately not the
	-- production backend shape; it exists so isolated service tests can supply a
	-- small object with start()/terminate().
	if type(driver.start) == 'function' then
		local ok, err = driver:start(lifetime_scope)
		if ok ~= true then return nil, err or 'backend_start_failed' end
		emit({ kind = 'backend_ready', component = 'backend', component_id = identity.component_id, generation = identity.generation }, 'http_backend_ready_report_failed')
		return component, nil
	end

	return nil, 'backend_driver_has_no_run_or_start'
end

return M
