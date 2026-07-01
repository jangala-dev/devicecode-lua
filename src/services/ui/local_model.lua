-- services/ui/local_model.lua
--
-- Pure retained-state projection for the temporary Vue/Tailwind local UI.
-- This module deliberately selects a small allow-list of useful retained topics
-- rather than exposing the full /api/state model to ordinary local pages.

local tablex = require 'shared.table'
local topicx = require 'shared.topic'
local topics = require 'services.ui.topics'

local M = {}

local copy = tablex.deep_copy
local starts_with = topicx.starts_with

local ALLOW_PREFIXES = {
	{ 'svc' },
	{ 'state', 'device' },
	{ 'state', 'net' },
	{ 'state', 'gsm' },
	{ 'state', 'fabric' },
	{ 'state', 'update' },
	{ 'state', 'workflow', 'update-job' },
	{ 'obs', 'v1', 'gsm', 'metric' },
	{ 'obs', 'v1', 'gsm', 'event' },
}

local DENY_PREFIXES = {
	{ 'cfg' },
	{ 'raw' },
	{ 'state', 'ui' },
	{ 'svc', 'ui' },
	{ 'obs', 'v1', 'ui' },
}

local function allowed(topic)
	for _, prefix in ipairs(DENY_PREFIXES) do
		if starts_with(topic, prefix) then return false end
	end
	for _, prefix in ipairs(ALLOW_PREFIXES) do
		if starts_with(topic, prefix) then return true end
	end
	return false
end

local function sorted_items(snapshot)
	local out = {}
	for _, msg in pairs((snapshot and snapshot.items) or {}) do
		if type(msg) == 'table' and type(msg.topic) == 'table' and allowed(msg.topic) then
			out[#out + 1] = {
				topic = copy(msg.topic),
				payload = copy(msg.payload),
				origin = copy(msg.origin),
			}
		end
	end
	table.sort(out, function(a, b)
		return topics.topic_key(a.topic) < topics.topic_key(b.topic)
	end)
	return out
end

function M.bootstrap(snapshot)
	local out = {}
	for _, msg in ipairs(sorted_items(snapshot)) do
		out[topics.topic_string(msg.topic)] = msg
	end
	return {
		schema = 'devicecode.ui.local-bootstrap/1',
		version = snapshot and snapshot.version or 0,
		items = out,
	}
end

M.allowed = allowed
M.ALLOW_PREFIXES = ALLOW_PREFIXES
M.DENY_PREFIXES = DENY_PREFIXES

return M
