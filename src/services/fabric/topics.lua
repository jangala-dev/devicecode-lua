-- services/fabric/topics.lua
--
-- Pure Fabric topic helpers.
--
-- This module must remain pure:
--   * no fibers.perform
--   * no scopes
--   * no queues
--   * no bus calls
--
-- It owns only topic construction and lightweight topic validation.

local topicx = require 'shared.topic'

local M = {}

local function scalar_ok(v)
	local tv = type(v)

	if tv == 'string' then
		return v ~= ''
	end

	if tv == 'number' then
		return v == v and v ~= math.huge and v ~= -math.huge
	end

	return false
end

local append = topicx.append

function M.append(base, ...)
	if type(base) ~= 'table' then
		error('topics.append: base must be a table', 2)
	end

	return append(base, ...)
end

function M.validate(topic)
	if type(topic) ~= 'table' then
		return nil, 'topic_must_be_table'
	end

	local max_i = 0
	local count = 0

	for k in pairs(topic) do
		if type(k) ~= 'number'
			or k < 1
			or k % 1 ~= 0
		then
			return nil, 'topic_must_be_dense_array'
		end

		if k > max_i then
			max_i = k
		end

		count = count + 1
	end

	if count ~= max_i then
		return nil, 'topic_must_be_dense_array'
	end

	for i = 1, max_i do
		if not scalar_ok(topic[i]) then
			return nil, 'invalid_topic_token'
		end
	end

	return topic, nil
end

--- Return a collision-safe string key for a literal Fabric topic.
---
--- The encoding distinguishes token type and token length, so topics such as
--- { "a/b" } and { "a", "b" } cannot collide.
function M.key(topic)
	local checked, err = M.validate(topic)
	if not checked then
		error('topics.key: ' .. tostring(err), 2)
	end

	local parts = {}
	for i = 1, #checked do
		local v = checked[i]

		if type(v) == 'string' then
			parts[#parts + 1] = 's' .. #v .. ':' .. v
		else
			local sv = tostring(v)
			parts[#parts + 1] = 'n' .. #sv .. ':' .. sv
		end
	end

	return table.concat(parts, '|')
end


function M.copy(topic)
	local checked, err = M.validate(topic)
	if not checked then
		error('topics.copy: ' .. tostring(err), 2)
	end

	local out = {}
	for i = 1, #checked do
		out[i] = checked[i]
	end
	return out
end

function M.starts_with(topic, prefix)
	local checked_topic, terr = M.validate(topic)
	if not checked_topic then
		error('topics.starts_with: topic ' .. tostring(terr), 2)
	end

	local checked_prefix, perr = M.validate(prefix)
	if not checked_prefix then
		error('topics.starts_with: prefix ' .. tostring(perr), 2)
	end

	if #checked_prefix > #checked_topic then
		return false
	end

	for i = 1, #checked_prefix do
		if checked_topic[i] ~= checked_prefix[i] then
			return false
		end
	end

	return true
end

function M.replace_prefix(topic, from_prefix, to_prefix)
	local checked_topic, terr = M.validate(topic)
	if not checked_topic then
		error('topics.replace_prefix: topic ' .. tostring(terr), 2)
	end

	local checked_from, ferr = M.validate(from_prefix)
	if not checked_from then
		error('topics.replace_prefix: from_prefix ' .. tostring(ferr), 2)
	end

	local checked_to, toerr = M.validate(to_prefix)
	if not checked_to then
		error('topics.replace_prefix: to_prefix ' .. tostring(toerr), 2)
	end

	if not M.starts_with(checked_topic, checked_from) then
		return nil, nil
	end

	local out = {}
	for i = 1, #checked_to do
		out[#out + 1] = checked_to[i]
	end
	for i = #checked_from + 1, #checked_topic do
		out[#out + 1] = checked_topic[i]
	end

	return out, nil
end

local function exact_match(mapped_to, wanted, topic)
	if #wanted ~= #topic then
		return nil, nil
	end

	for i = 1, #topic do
		if topic[i] ~= wanted[i] then
			return nil, nil
		end
	end

	return M.copy(mapped_to), nil
end

local function match_rule(rule, topic, from_field, to_field)
	if type(rule) ~= 'table' then
		error('topics.match_rule: rule must be a table', 3)
	end

	local checked_topic, terr = M.validate(topic)
	if not checked_topic then
		error('topics.match_rule: topic ' .. tostring(terr), 3)
	end

	local to_topic = rule[to_field]
	local checked_to, toerr = M.validate(to_topic)
	if not checked_to then
		error('topics.match_rule: ' .. tostring(to_field) .. ' ' .. tostring(toerr), 3)
	end

	if rule.topic then
		local wanted, werr = M.validate(rule.topic)
		if not wanted then
			error('topics.match_rule: topic field ' .. tostring(werr), 3)
		end
		local mapped = exact_match(checked_to, wanted, checked_topic)
		if mapped then
			return mapped, rule
		end
		return nil, nil
	end

	local from_topic = rule[from_field]
	local checked_from, ferr = M.validate(from_topic)
	if not checked_from then
		error('topics.match_rule: ' .. tostring(from_field) .. ' ' .. tostring(ferr), 3)
	end

	local mapped = M.replace_prefix(checked_topic, checked_from, checked_to)
	if mapped then
		return mapped, rule
	end

	return nil, nil
end

local function match_rule_set(rules, topic, from_field, to_field)
	if rules == nil then
		return nil, nil
	end
	if type(rules) ~= 'table' then
		error('topics.match_rule_set: rules must be a table', 3)
	end

	for i = 1, #rules do
		local mapped, rule = match_rule(rules[i], topic, from_field, to_field)
		if mapped then
			return mapped, rule
		end
	end

	return nil, nil
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


local function match_exact_rule(rule, topic, from_field, to_field)
	if type(rule) ~= 'table' then
		error('topics.match_exact_rule: rule must be a table', 3)
	end

	local checked_topic, terr = M.validate(topic)
	if not checked_topic then
		error('topics.match_exact_rule: topic ' .. tostring(terr), 3)
	end

	local from_topic, ferr = M.validate(rule[from_field])
	if not from_topic then
		error('topics.match_exact_rule: ' .. tostring(from_field) .. ' ' .. tostring(ferr), 3)
	end

	local to_topic, toerr = M.validate(rule[to_field])
	if not to_topic then
		error('topics.match_exact_rule: ' .. tostring(to_field) .. ' ' .. tostring(toerr), 3)
	end

	if #checked_topic ~= #from_topic then
		return nil, nil
	end

	for i = 1, #from_topic do
		if checked_topic[i] ~= from_topic[i] then
			return nil, nil
		end
	end

	return M.copy(to_topic), rule
end

local function match_exact_rule_set(rules, topic, from_field, to_field)
	if rules == nil then
		return nil, nil
	end
	if type(rules) ~= 'table' then
		error('topics.match_exact_rule_set: rules must be a table', 3)
	end

	for i = 1, #rules do
		local mapped, rule = match_exact_rule(rules[i], topic, from_field, to_field)
		if mapped then
			return mapped, rule
		end
	end

	return nil, nil
end

function M.map_local_call_to_remote(rules, topic)
	return match_exact_rule_set(rules, topic, 'local_topic', 'remote_topic')
end

function M.map_remote_call_to_local(rules, topic)
	return match_exact_rule_set(rules, topic, 'remote_topic', 'local_topic')
end

function M.map_local_call_to_remote_rule(rule, topic)
	return match_exact_rule(rule, topic, 'local_topic', 'remote_topic')
end

function M.map_remote_call_to_local_rule(rule, topic)
	return match_exact_rule(rule, topic, 'remote_topic', 'local_topic')
end

--------------------------------------------------------------------------------
-- Service-level topics
--------------------------------------------------------------------------------

function M.svc_status()
	return { 'svc', 'fabric', 'status' }
end

function M.svc_meta()
	return { 'svc', 'fabric', 'meta' }
end

function M.cfg()
	return { 'cfg', 'fabric' }
end

--------------------------------------------------------------------------------
-- Fabric state plane
--------------------------------------------------------------------------------

function M.state_root()
	return { 'state', 'fabric' }
end

function M.state_link(link_id, ...)
	return append({ 'state', 'fabric', 'link', link_id }, ...)
end

function M.state_link_component(link_id, component)
	return append({ 'state', 'fabric', 'link', link_id, 'component' }, component)
end

--------------------------------------------------------------------------------
-- Stable public Fabric interfaces
--------------------------------------------------------------------------------

function M.transfer_manager_meta(id)
	return { 'cap', 'transfer-manager', id or 'main', 'meta' }
end

function M.transfer_manager_status(id)
	return { 'cap', 'transfer-manager', id or 'main', 'status' }
end

function M.transfer_manager_rpc(method, id)
	return { 'cap', 'transfer-manager', id or 'main', 'rpc', method }
end

return M
