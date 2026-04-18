local topicmap = require 'services.fabric.topicmap'

local T = {}

function T.exact_topic_rules_match_only_the_declared_topic()
	local rules = topicmap.normalise_prefix_rules({
		{ topic = { 'cmd', 'fabric', 'transfer' }, ['remote'] = { 'rpc', 'fabric', 'transfer' } },
	}, 'exact')

	local mapped1, rule1 = topicmap.map_local_to_remote(rules, { 'cmd', 'fabric', 'transfer' })
	assert(rule1 ~= nil)
	assert(mapped1[1] == 'rpc')
	assert(mapped1[2] == 'fabric')
	assert(mapped1[3] == 'transfer')

	local mapped2, rule2 = topicmap.map_local_to_remote(rules, { 'cmd', 'fabric', 'other' })
	assert(mapped2 == nil)
	assert(rule2 == nil)
end

function T.exact_topic_rule_takes_precedence_over_broader_prefix_rule_when_placed_first()
	local rules = topicmap.normalise_prefix_rules({
		{ topic = { 'cmd', 'fabric', 'transfer' }, ['remote'] = { 'rpc', 'exact' } },
		{ ['local'] = { 'cmd', 'fabric' }, ['remote'] = { 'rpc', 'prefix' } },
	}, 'exact')

	local mapped = assert((topicmap.map_local_to_remote(rules, { 'cmd', 'fabric', 'transfer' })))
	assert(mapped[1] == 'rpc')
	assert(mapped[2] == 'exact')
	assert(#mapped == 2)
end

return T
