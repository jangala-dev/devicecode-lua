-- tests/services/fabric/test_topics.lua

local topics = require 'services.fabric.topics'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_eq(a, b, msg)
	if a ~= b then
		fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
	end
end

local function assert_nil(v, msg)
	if v ~= nil then
		fail(msg or ('expected nil, got ' .. tostring(v)))
	end
end

local function assert_not_nil(v, msg)
	if v == nil then
		fail(msg or 'expected non-nil value')
	end
end

local function assert_topic(t, expected)
	assert_eq(#t, #expected, 'topic length mismatch')

	for i = 1, #expected do
		assert_eq(t[i], expected[i], 'topic token mismatch at ' .. tostring(i))
	end
end

function tests.test_service_topics()
	assert_topic(topics.svc_status(), { 'svc', 'fabric', 'status' })
	assert_topic(topics.svc_meta(), { 'svc', 'fabric', 'meta' })
	assert_topic(topics.cfg(), { 'cfg', 'fabric' })
end

function tests.test_state_link_topics()
	assert_topic(
		topics.state_root(),
		{ 'state', 'fabric' }
	)

	assert_topic(
		topics.state_link('link-a', 'session', 'status'),
		{ 'state', 'fabric', 'link', 'link-a', 'session', 'status' }
	)

	assert_topic(
		topics.state_link_component('link-a', 'reader'),
		{ 'state', 'fabric', 'link', 'link-a', 'component', 'reader' }
	)
end

function tests.test_topic_helpers_return_fresh_tables()
	local a = topics.svc_status()
	local b = topics.svc_status()

	a[1] = 'changed'

	assert_topic(b, { 'svc', 'fabric', 'status' })
end

function tests.test_validate_accepts_dense_scalar_topics()
	local ok, err = topics.validate({ 'raw', 'member', 7, 'status' })

	assert_not_nil(ok)
	assert_nil(err)
end

function tests.test_validate_rejects_bad_topics()
	local ok, err = topics.validate('not-topic')

	assert_nil(ok)
	assert_eq(err, 'topic_must_be_table')

	ok, err = topics.validate({ 'raw', {}, 'bad' })

	assert_nil(ok)
	assert_eq(err, 'invalid_topic_token')

	local sparse = { 'raw', 'member' }
	sparse[4] = 'bad'

	ok, err = topics.validate(sparse)

	assert_nil(ok)
	assert_eq(err, 'topic_must_be_dense_array')
end

function tests.test_topic_key_is_collision_safe_and_type_aware()
	local a = topics.key({ 'a/b' })
	local b = topics.key({ 'a', 'b' })
	local c = topics.key({ 12 })
	local d = topics.key({ '12' })

	if a == b then
		fail('single-token and two-token topic keys collided')
	end

	if c == d then
		fail('numeric and string topic keys collided')
	end
end


function tests.test_topic_mapping_helpers_replace_prefix_and_return_matching_rule()
	local rules = {
		{
			id = 'state-import',
			local_prefix = { 'raw', 'member', 'node-a', 'state' },
			remote_prefix = { 'state' },
		},
	}

	local remote, rule = topics.map_local_to_remote(rules, {
		'raw', 'member', 'node-a', 'state', 'battery', 'voltage'
	})

	assert_not_nil(remote)
	assert_eq(rule, rules[1])
	assert_topic(remote, { 'state', 'battery', 'voltage' })

	local local_topic = topics.map_remote_to_local(rules, remote)
	assert_topic(local_topic, { 'raw', 'member', 'node-a', 'state', 'battery', 'voltage' })
end

function tests.test_topic_mapping_helpers_support_exact_topic_rules()
	local rule = {
		topic = { 'cap', 'diag', 'rpc', 'read' },
		local_prefix = { 'cap', 'diag', 'rpc', 'read' },
		remote_prefix = { 'rpc', 'diag.read' },
	}

	local mapped, matched = topics.map_local_to_remote_rule(rule, { 'cap', 'diag', 'rpc', 'read' })
	assert_not_nil(mapped)
	assert_eq(matched, rule)
	assert_topic(mapped, { 'rpc', 'diag.read' })

	local none = topics.map_local_to_remote_rule(rule, { 'cap', 'diag', 'rpc', 'write' })
	assert_nil(none)
end


function tests.test_topic_mapping_helpers_support_exact_rpc_call_rules()
	local rules = {
		{
			id = 'diag-read',
			local_topic = { 'cap', 'diag', 'rpc', 'read' },
			remote_topic = { 'rpc', 'diag.read' },
		},
	}

	local remote, rule = topics.map_local_call_to_remote(rules, { 'cap', 'diag', 'rpc', 'read' })
	assert_not_nil(remote)
	assert_eq(rule, rules[1])
	assert_topic(remote, { 'rpc', 'diag.read' })

	local local_topic = topics.map_remote_call_to_local(rules, remote)
	assert_topic(local_topic, { 'cap', 'diag', 'rpc', 'read' })

	local not_remote = topics.map_local_call_to_remote(rules, { 'cap', 'diag', 'rpc', 'read', 'extra' })
	assert_nil(not_remote)

	local not_local = topics.map_remote_call_to_local(rules, { 'rpc', 'diag.read', 'extra' })
	assert_nil(not_local)
end

return tests
