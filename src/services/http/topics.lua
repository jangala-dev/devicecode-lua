-- services/http/topics.lua
-- Pure topic helpers for cap/http/<id>.

local topic = require 'shared.topic'

local M = {}

local function cap(id)
	return { 'cap', 'http', id or 'main' }
end

function M.base(id) return cap(id) end
function M.meta(id) return topic.append(cap(id), 'meta') end
function M.status(id) return topic.append(cap(id), 'status') end
function M.state(id, key) return topic.append(cap(id), 'state', key) end
function M.event(id, name) return topic.append(cap(id), 'event', name) end
function M.obs_metric(id, name) return { 'obs', 'v1', 'http', 'metric', id or 'main', name } end
function M.obs_log(id, level) return { 'obs', 'v1', 'http', 'log', id or 'main', level or 'info' } end
function M.rpc(id, verb) return topic.append(cap(id), 'rpc', verb) end

return M
