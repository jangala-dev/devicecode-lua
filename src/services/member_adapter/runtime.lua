local topics = require 'services.device.topics'

local M = {}
local Runtime = {}
Runtime.__index = Runtime

local function copy_array(t)
  local out = {}
  if type(t) ~= 'table' then return out end
  for i = 1, #t do out[i] = t[i] end
  return out
end

local function append(base, suffix)
  local out = copy_array(base)
  if type(suffix) == 'table' then
    for i = 1, #suffix do out[#out + 1] = suffix[i] end
  end
  return out
end

function M.new(conn, member)
  assert(type(member) == 'string' and member ~= '', 'member_adapter.runtime: member required')
  return setmetatable({ conn = conn, member = member }, Runtime)
end

function Runtime:state_topic(suffix)
  return append(topics.member_state(self.member), suffix)
end

function Runtime:event_topic(suffix)
  return append(topics.member_event(self.member), suffix)
end

function Runtime:retain_state(suffix, payload)
  return self.conn:retain(self:state_topic(suffix), payload)
end

function Runtime:unretain_state(suffix)
  return self.conn:unretain(self:state_topic(suffix))
end

function Runtime:publish_event(suffix, payload)
  return self.conn:publish(self:event_topic(suffix), payload)
end

return M
