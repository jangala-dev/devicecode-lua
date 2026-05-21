local dep_failure = require 'devicecode.support.dependency_failure'

local T = {}

function T.canonical_no_route_failure_is_strict_and_copied()
	local detail = { err = 'no_route', nested = { a = 1 } }
	local failure = dep_failure.no_route('transport:uart0', detail, { source = 'uart' })
	assert(failure.kind == 'dependency_failure')
	assert(failure.err == 'no_route')
	assert(failure.dependency_key == 'transport:uart0')
	assert(failure.source == 'uart')
	assert(dep_failure.is(failure))
	assert(dep_failure.is_no_route(failure))
	detail.nested.a = 2
	assert(failure.detail.nested.a == 1)
end

function T.no_route_classifier_does_not_search_wrappers_or_nested_reason_tables()
	assert(dep_failure.is_no_route('no_route'))
	assert(dep_failure.is_no_route({ err = 'no_route' }))
	assert(dep_failure.is_no_route({ result = { err = 'no_route' } }))
	assert(not dep_failure.is_no_route({ primary = { err = 'no_route' } }))
	assert(not dep_failure.is_no_route({ report = { primary = { err = 'no_route' } } }))
	assert(not dep_failure.is_no_route({ children = { { primary = { err = 'no_route' } } } }))
	assert(not dep_failure.is_no_route({ reason = { err = 'no_route' } }))
end

function T.from_no_route_requires_key_and_direct_no_route_shape()
	assert(dep_failure.from_no_route(nil, 'no_route') == nil)
	assert(dep_failure.from_no_route('transport:uart0', { reason = { err = 'no_route' } }) == nil)
	local failure = dep_failure.from_no_route('transport:uart0', { err = 'no_route' }, { link_id = 'uart0' })
	assert(failure.kind == 'dependency_failure')
	assert(failure.err == 'no_route')
	assert(failure.dependency_key == 'transport:uart0')
	assert(failure.link_id == 'uart0')
end

return T
