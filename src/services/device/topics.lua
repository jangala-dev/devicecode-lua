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
function M.component_event(name, event_name) return { 'cap', 'component', name, 'event', event_name } end
function M.component_cap_meta(name) return { 'cap', 'component', name, 'meta' } end
function M.component_cap_status(name) return { 'cap', 'component', name, 'status' } end
function M.component_cap_rpc(name, method) return { 'cap', 'component', name, 'rpc', method } end

function M.raw_member_meta(member) return { 'raw', 'member', member, 'meta' } end
function M.raw_member_status(member) return { 'raw', 'member', member, 'status' } end
function M.raw_member_state(member, ...) return append({ 'raw', 'member', member, 'state' }, ...) end
function M.raw_member_cap_meta(member, class, id) return { 'raw', 'member', member, 'cap', class, id, 'meta' } end
function M.raw_member_cap_status(member, class, id) return { 'raw', 'member', member, 'cap', class, id, 'status' } end
function M.raw_member_cap_state(member, class, id, ...) return append({ 'raw', 'member', member, 'cap', class, id, 'state' }, ...) end
function M.raw_member_cap_rpc(member, class, id, method) return { 'raw', 'member', member, 'cap', class, id, 'rpc', method } end
function M.raw_member_cap_event(member, class, id, ...) return append({ 'raw', 'member', member, 'cap', class, id, 'event' }, ...) end

-- internal compatibility aliases during service-local migration
function M.self() return M.identity() end
function M.member_state(member, ...) return M.raw_member_state(member, ...) end
function M.member_event(member, ...) return M.raw_member_cap_event(member, 'telemetry', 'main', ...) end
function M.cap_updater_state(component, fact) return { 'cap', 'updater', component, 'state', fact } end
function M.cap_updater_rpc(component, method) return { 'cap', 'updater', component, 'rpc', method } end

return M
