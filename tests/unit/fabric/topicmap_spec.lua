local topicmap = require 'services.fabric.topicmap'

local T = {}

function T.match_and_substitute_single_and_multi_wildcards()
	local ok, caps = topicmap.match(
		{ 'state', '+', '#' },
		{ 'state', 'net', 'link', 'wan0' }
	)

	assert(ok == true)
	assert(type(caps) == 'table')
	assert(caps.plus[1] == 'net')
	assert(#caps.hash == 2)
	assert(caps.hash[1] == 'link')
	assert(caps.hash[2] == 'wan0')

	local out = topicmap.substitute(
		{ 'peer', 'mcu-1', '+', '#' },
		caps
	)

	assert(#out == 5)
	assert(out[1] == 'peer')
	assert(out[2] == 'mcu-1')
	assert(out[3] == 'net')
	assert(out[4] == 'link')
	assert(out[5] == 'wan0')
end

function T.apply_first_maps_src_to_dst()
	local mapped, rule = topicmap.apply_first({
		{
			remote_topic = { 'state', '#' },
			local_topic  = { 'peer', 'mcu-1', 'state', '#' },
		},
	}, { 'state', 'foo', 'bar' }, 'remote_topic', 'local_topic')

	assert(rule ~= nil)
	assert(type(mapped) == 'table')
	assert(#mapped == 5)
	assert(mapped[1] == 'peer')
	assert(mapped[2] == 'mcu-1')
	assert(mapped[3] == 'state')
	assert(mapped[4] == 'foo')
	assert(mapped[5] == 'bar')
end

return T
