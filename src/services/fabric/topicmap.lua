-- services/fabric/topicmap.lua
--
-- Declarative topic mapping helpers used by fabric bridge rules.
--
-- Notes:
--   * rules are order-sensitive
--   * exact-topic rules are supported via `topic = {...}`
--   * broader prefix replacement only applies if no earlier rule matched
--   * accepted rule keys are:
--       - local
--       - remote
--       - topic
--       - timeout

local M = {}

local function copy_topic(topic)
	local out = {}
	for i = 1, #topic do
		out[i] = topic[i]
	end
	return out
end

local function normalise_topic(t)
	assert(type(t) == 'table', 'topic must be a table')
	return copy_topic(t)
end

local function starts_with(topic, prefix)
	if #prefix > #topic then return false end
	for i = 1, #prefix do
		if topic[i] ~= prefix[i] then
			return false
		end
	end
	return true
end

local function replace_prefix(topic, from_prefix, to_prefix)
	if not starts_with(topic, from_prefix) then
		return nil
	end

	local out = {}
	for i = 1, #to_prefix do
		out[#out + 1] = to_prefix[i]
	end
	for i = #from_prefix + 1, #topic do
		out[#out + 1] = topic[i]
	end
	return out
end

local function has_legacy_aliases(rule)
	return rule.local_prefix ~= nil
		or rule.from ~= nil
		or rule.from_prefix ~= nil
		or rule.remote_prefix ~= nil
		or rule.to ~= nil
		or rule.to_prefix ~= nil
end

local function normalise_rule(rule, kind)
	assert(type(rule) == 'table', kind .. ' rule must be a table')

	if has_legacy_aliases(rule) then
		error(kind .. ' rule must use "local" and "remote" keys only', 2)
	end

	local local_prefix = normalise_topic(rule['local'] or {})
	local remote_prefix = normalise_topic(rule['remote'] or {})

	return {
		id = rule.id,
		local_prefix = local_prefix,
		remote_prefix = remote_prefix,
		topic = rule.topic and normalise_topic(rule.topic) or nil,
		timeout = rule.timeout,
		direction = kind,
	}
end

local function match_rule(rule, topic, from_field, to_field)
	if rule.topic then
		local wanted = rule.topic
		if #wanted ~= #topic then
			return nil, nil
		end

		for i = 1, #topic do
			if topic[i] ~= wanted[i] then
				return nil, nil
			end
		end

		return copy_topic(rule[to_field]), rule
	end

	local mapped = replace_prefix(topic, rule[from_field], rule[to_field])
	if mapped then
		return mapped, rule
	end

	return nil, nil
end

local function match_rule_set(rules, topic, from_field, to_field)
	for i = 1, #rules do
		local mapped, rule = match_rule(rules[i], topic, from_field, to_field)
		if mapped then
			return mapped, rule
		end
	end
	return nil, nil
end

function M.normalise_prefix_rules(list, kind)
	local out = {}
	for i = 1, #(list or {}) do
		out[#out + 1] = normalise_rule(list[i], kind)
	end
	return out
end

function M.map_local_to_remote(rules, topic)
	return match_rule_set(rules, topic, 'local_prefix', 'remote_prefix')
end

function M.map_remote_to_local(rules, topic)
	return match_rule_set(rules, topic, 'remote_prefix', 'local_prefix')
end

function M.map_local_to_remote_rule(rule, topic)
	return match_rule(rule, topic, 'local_prefix', 'remote_prefix')
end

function M.map_remote_to_local_rule(rule, topic)
	return match_rule(rule, topic, 'remote_prefix', 'local_prefix')
end

return M
