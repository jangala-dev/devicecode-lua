local M = {}

local function copy_array(t)
  local out = {}
  if type(t) ~= 'table' then return out end
  for i = 1, #t do out[i] = t[i] end
  return out
end

local function append(base, ...)
  local out = copy_array(base)
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    if type(v) == 'table' then
      for j = 1, #v do out[#out + 1] = v[j] end
    else
      out[#out + 1] = v
    end
  end
  return out
end

function M.copy(topic) return copy_array(topic) end

function M.identity() return { 'state', 'device', 'identity' } end
function M.components() return { 'state', 'device', 'components' } end
function M.component(name) return { 'state', 'device', 'component', name } end
function M.component_software(name) return append(M.component(name), 'software') end
function M.component_update(name) return append(M.component(name), 'update') end
function M.component_cap_meta(name) return { 'cap', 'component', name, 'meta' } end
function M.component_cap_status(name) return { 'cap', 'component', name, 'status' } end
function M.component_cap_rpc(name, method) return { 'cap', 'component', name, 'rpc', method } end
function M.component_cap_event(name, event) return { 'cap', 'component', name, 'event', event } end


function M.raw_member_meta(member) return { 'raw', 'member', member, 'meta' } end
function M.raw_member_status(member) return { 'raw', 'member', member, 'status' } end
function M.raw_member_state(member, ...) return append({ 'raw', 'member', member, 'state' }, ...) end
function M.raw_member_cap_meta(member, class, id) return { 'raw', 'member', member, 'cap', class, id, 'meta' } end
function M.raw_member_cap_status(member, class, id) return { 'raw', 'member', member, 'cap', class, id, 'status' } end
function M.raw_member_cap_state(member, class, id, ...) return append({ 'raw', 'member', member, 'cap', class, id, 'state' }, ...) end
function M.raw_member_cap_rpc(member, class, id, method) return { 'raw', 'member', member, 'cap', class, id, 'rpc', method } end
function M.raw_member_cap_event(member, class, id, ...) return append({ 'raw', 'member', member, 'cap', class, id, 'event' }, ...) end


function M.raw_host_cap_meta(source, class, id) return { 'raw', 'host', source, 'cap', class, id, 'meta' } end
function M.raw_host_cap_status(source, class, id) return { 'raw', 'host', source, 'cap', class, id, 'status' } end
function M.raw_host_cap_state(source, class, id, ...) return append({ 'raw', 'host', source, 'cap', class, id, 'state' }, ...) end
function M.raw_host_cap_rpc(source, class, id, method) return { 'raw', 'host', source, 'cap', class, id, 'rpc', method } end

return M
