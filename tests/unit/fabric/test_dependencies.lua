local deps = require 'services.fabric.dependencies'
local cfg = require 'services.fabric.config'

local T = {}

function T.derives_raw_host_transport_dependency_for_hal_link()
	local compiled = assert(cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {{ id = 'uart0', peer_id = 'peer', transport = { source = 'uart', class = 'uart', id = 'main' }, bridge = {}, transfer = {} }},
	}))
	local specs = deps.transport_dependencies(compiled)
	assert(#specs == 1)
	assert(specs[1].key == 'transport:uart0')
	assert(specs[1].raw_kind == 'host')
	assert(specs[1].source == 'uart')
	assert(specs[1].class == 'uart')
	assert(specs[1].id == 'main')
end

function T.override_transport_bypasses_dependency()
	local compiled = assert(cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {{ id = 'uart0', peer_id = 'peer', transport = { source = 'uart', class = 'uart', id = 'main' }, bridge = {}, transfer = {} }},
	}))
	local specs = deps.transport_dependencies(compiled, { uart0 = { open_transport_op = function () end } })
	assert(#specs == 0)
end


function T.accepts_only_canonical_dependency_failure_from_generation_failure()
	local service = require 'services.fabric.service'
	local state = {
		generation_deps = {
			dependency = function (_, key)
				if key == 'transport:uart0' then return { key = key } end
				return nil
			end,
		},
	}
	local key, failure = service._test.generation_route_failure(state, {
		primary = {
			kind = 'dependency_failure',
			err = 'no_route',
			dependency_key = 'transport:uart0',
		},
	})
	assert(key == 'transport:uart0')
	assert(failure.dependency_key == 'transport:uart0')
end

function T.rejects_legacy_or_nested_dependency_failure_shapes()
	local service = require 'services.fabric.service'
	local state = {
		generation_deps = {
			dependency = function (_, key)
				if key == 'transport:uart0' then return { key = key } end
				return nil
			end,
		},
	}
	local key = service._test.generation_route_failure(state, {
		primary = 'link uart0 failed: no_route [dependency_key=transport:uart0]',
	})
	assert(key == nil)
	key = service._test.generation_route_failure(state, {
		report = { children = { { primary = { dependency_key = 'transport:uart0', err = 'no_route' } } } },
	})
	assert(key == nil)
end


function T.hal_transport_open_errors_preserve_dependency_key()
	local hal_transport = require 'services.fabric.hal_transport'
	local _, err = hal_transport.unwrap_open_transport_reply({
		dependency_key = 'transport:uart0',
		source = 'uart',
		class = 'uart',
		id = 'main',
	}, nil, 'no_route')
	assert(type(err) == 'table')
	assert(err.kind == 'dependency_failure')
	assert(err.err == 'no_route')
	assert(err.dependency_key == 'transport:uart0')
	assert(err.source == 'uart')
end

function T.default_policy_preserves_structured_dependency_key()
	local service = require 'services.fabric.service'
	local decision = service.default_policy(nil, {
		kind = 'link_done',
		status = 'failed',
		link_id = 'uart0',
		primary = { kind = 'dependency_failure', err = 'no_route', dependency_key = 'transport:uart0' },
	})
	assert(decision.action == 'fail')
	assert(type(decision.reason) == 'table')
	assert(decision.reason.kind == 'dependency_failure')
	assert(decision.reason.err == 'no_route')
	assert(decision.reason.dependency_key == 'transport:uart0')
	assert(decision.reason.link_id == 'uart0')
end


return T
