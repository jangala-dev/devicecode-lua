-- tests/ui_cqueues_bridge_spec.lua

local safe = require 'coxpcall'

local T = {}

local function with_stubbed_modules(stubs, fn)
	local saved_preload = {}
	local saved_loaded  = {}

	for name, loader in pairs(stubs) do
		saved_preload[name] = package.preload[name]
		saved_loaded[name]  = package.loaded[name]
		package.preload[name] = function()
			return loader
		end
		package.loaded[name] = nil
	end

	package.loaded['services.ui.cqueues_bridge'] = nil

	local ok, a, b, c = safe.pcall(fn)

	package.loaded['services.ui.cqueues_bridge'] = nil

	for name, _ in pairs(stubs) do
		package.preload[name] = saved_preload[name]
		package.loaded[name]  = saved_loaded[name]
	end

	if not ok then
		error(a, 0)
	end

	return a, b, c
end

function T.bridge_install_is_idempotent()
	local interpose_calls = 0
	local installed_wrapper = nil

	local fake_old_step = function(self, timeout)
		return 'old-step', timeout
	end

	with_stubbed_modules({
		['cqueues'] = {
			running = function() return false end,
			interpose = function(name, wrapper)
				assert(name == 'step')
				interpose_calls = interpose_calls + 1
				installed_wrapper = wrapper
				return fake_old_step
			end,
		},
		['fibers'] = {
			perform = function(_) error('fibers.perform should not be called in this test') end,
		},
		['fibers.op'] = {
			new_primitive = function(_, _, _) return { tag = 'primitive' } end,
			choice = function(...) return { tag = 'choice', n = select('#', ...) } end,
		},
		['fibers.sleep'] = {
			sleep_op = function(dt) return { tag = 'sleep', dt = dt } end,
		},
		['fibers.runtime'] = {
			current_fiber = function() return nil end,
			yield = function() error('yield should not be called in this test') end,
		},
		['fibers.io.poller'] = {
			get = function()
				return {
					wait = function(_, _, _, _) return { unlink = function() end } end,
				}
			end,
		},
	}, function()
		local bridge = require 'services.ui.cqueues_bridge'
		assert(type(bridge.install) == 'function')

		assert(bridge.install() == true)
		assert(bridge.install() == true)

		assert(interpose_calls == 1)
		assert(type(installed_wrapper) == 'function')
	end)
end

function T.bridge_external_step_builds_wait_choices_and_calls_old_step_zero()
	local installed_wrapper = nil
	local old_step_calls = {}
	local perform_calls = {}
	local choice_calls = {}
	local primitive_calls = {}
	local sleep_calls = {}

	local fake_old_step = function(self, timeout)
		old_step_calls[#old_step_calls + 1] = {
			self = self,
			timeout = timeout,
		}
		return 'old-step-result', timeout
	end

	with_stubbed_modules({
		['cqueues'] = {
			running = function() return false end,
			interpose = function(name, wrapper)
				assert(name == 'step')
				installed_wrapper = wrapper
				return fake_old_step
			end,
		},
		['fibers'] = {
			perform = function(ev)
				perform_calls[#perform_calls + 1] = ev
				return true
			end,
		},
		['fibers.op'] = {
			new_primitive = function(_, try_fn, block_fn)
				local ev = {
					tag = 'primitive',
					try_fn = try_fn,
					block_fn = block_fn,
				}
				primitive_calls[#primitive_calls + 1] = ev
				return ev
			end,
			choice = function(...)
				local ev = {
					tag = 'choice',
					args = { ... },
					n = select('#', ...),
				}
				choice_calls[#choice_calls + 1] = ev
				return ev
			end,
		},
		['fibers.sleep'] = {
			sleep_op = function(dt)
				local ev = { tag = 'sleep', dt = dt }
				sleep_calls[#sleep_calls + 1] = ev
				return ev
			end,
		},
		['fibers.runtime'] = {
			current_fiber = function() return nil end,
			yield = function() error('yield should not be called in external step test') end,
		},
		['fibers.io.poller'] = {
			get = function()
				return {
					wait = function(_, fd, want, task)
						assert(type(fd) == 'number')
						assert(want == 'rd' or want == 'wr')
						assert(type(task) == 'table' and type(task.run) == 'function')
						return {
							unlink = function() return false end,
						}
					end,
				}
			end,
		},
	}, function()
		local bridge = require 'services.ui.cqueues_bridge'
		bridge.install()

		assert(type(installed_wrapper) == 'function')

		local fake_cq = {
			timeout = function() return 2.5 end,
			events  = function() return 'rw' end,
			pollfd  = function() return 9 end,
		}

		local r1, r2 = installed_wrapper(fake_cq, nil)

		assert(r1 == 'old-step-result')
		assert(r2 == 0.0)

		assert(#primitive_calls == 2)   -- rd + wr
		assert(#sleep_calls == 1)       -- timeout
		assert(#choice_calls == 1)
		assert(choice_calls[1].n == 3)
		assert(#perform_calls == 1)
		assert(perform_calls[1] == choice_calls[1])

		assert(#old_step_calls == 1)
		assert(old_step_calls[1].self == fake_cq)
		assert(old_step_calls[1].timeout == 0.0)
	end)
end

function T.bridge_running_inside_fiber_yields_then_calls_old_step_with_original_timeout()
	local installed_wrapper = nil
	local old_step_calls = 0
	local yielded = 0

	local fake_old_step = function(self, timeout)
		old_step_calls = old_step_calls + 1
		return 'ok', timeout
	end

	with_stubbed_modules({
		['cqueues'] = {
			running = function() return true end,
			interpose = function(name, wrapper)
				assert(name == 'step')
				installed_wrapper = wrapper
				return fake_old_step
			end,
		},
		['fibers'] = {
			perform = function(_) error('fibers.perform should not be called in running branch') end,
		},
		['fibers.op'] = {
			new_primitive = function(_, _, _) return { tag = 'primitive' } end,
			choice = function(...) return { tag = 'choice', n = select('#', ...) } end,
		},
		['fibers.sleep'] = {
			sleep_op = function(dt) return { tag = 'sleep', dt = dt } end,
		},
		['fibers.runtime'] = {
			current_fiber = function() return { tag = 'fiber' } end,
			yield = function() yielded = yielded + 1 end,
		},
		['fibers.io.poller'] = {
			get = function()
				return {
					wait = function(_, _, _, _) return { unlink = function() end } end,
				}
			end,
		},
	}, function()
		local bridge = require 'services.ui.cqueues_bridge'
		bridge.install()

		local fake_cq = {}
		local r1, r2 = installed_wrapper(fake_cq, 1.25)

		assert(r1 == 'ok')
		assert(r2 == 1.25)
		assert(yielded == 1)
		assert(old_step_calls == 1)
	end)
end

return T
