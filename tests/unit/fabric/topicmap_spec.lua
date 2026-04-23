local topicmap = require 'services.fabric.topicmap'

local T = {}

function T.normalise_prefix_rules_accepts_reserved_keys()
	local rules = topicmap.normalise_prefix_rules({
		{ ['local'] = { 'a' }, ['remote'] = { 'b' } },
	}, 'test')
	assert(#rules == 1)
	assert(rules[1].local_prefix[1] == 'a')
	assert(rules[1].remote_prefix[1] == 'b')
end

function T.map_local_to_remote_replaces_prefix()
	local rules = topicmap.normalise_prefix_rules({
		{ ['local'] = { 'obs' }, ['remote'] = { 'remote', 'obs' } },
	}, 'export')
	local mapped, rule = topicmap.map_local_to_remote(rules, { 'obs', 'wifi', 'up' })
	assert(rule ~= nil)
	assert(mapped[1] == 'remote')
	assert(mapped[2] == 'obs')
	assert(mapped[3] == 'wifi')
	assert(mapped[4] == 'up')
end

function T.map_remote_to_local_replaces_prefix()
	local rules = topicmap.normalise_prefix_rules({
		{ ['local'] = { 'seen' }, ['remote'] = { 'remote' } },
	}, 'import')
	local mapped = topicmap.map_remote_to_local(rules, { 'remote', 'net', 'wan' })
	assert(mapped[1] == 'seen')
	assert(mapped[2] == 'net')
	assert(mapped[3] == 'wan')
end

return T
