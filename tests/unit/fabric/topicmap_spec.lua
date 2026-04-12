local topicmap = require 'services.fabric.topicmap'

local T = {}

function T.match_captures_plus_and_hash_segments()
	local ok, caps = topicmap.match({ 'obs', '+', '#' }, { 'obs', 'net', 'link', 'wan' })
	assert(ok == true)
	assert(type(caps) == 'table')
	assert(caps.plus[1] == 'net')
	assert(#caps.hash == 2)
	assert(caps.hash[1] == 'link')
	assert(caps.hash[2] == 'wan')
end

function T.substitute_replays_captures_into_template()
	local mapped = topicmap.substitute({ 'remote', '+', '#' }, {
		plus = { 'wifi' },
		hash = { 'state', 'up' },
	})

	assert(#mapped == 4)
	assert(mapped[1] == 'remote')
	assert(mapped[2] == 'wifi')
	assert(mapped[3] == 'state')
	assert(mapped[4] == 'up')
end

function T.apply_first_returns_first_matching_rule()
	local mapped, rule = topicmap.apply_first({
		{
			local_topic = { 'a', '+' },
			remote_topic = { 'b', '+' },
		},
		{
			local_topic = { 'a', '#' },
			remote_topic = { 'c', '#' },
		},
	}, { 'a', 'x' }, 'local_topic', 'remote_topic')

	assert(rule ~= nil)
	assert(mapped[1] == 'b')
	assert(mapped[2] == 'x')
end

return T
