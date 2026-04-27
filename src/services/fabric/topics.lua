-- services/fabric/topics.lua
--
-- Canonical topic helpers for the fabric service.  These helpers keep the
-- public fabric summary plane separate from provenance-bearing raw member
-- truth and curated public manager interfaces.

local M = {}

local function append(base, ...)
  local out = {}
  for i = 1, #base do out[i] = base[i] end
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

function M.svc_status() return { 'svc', 'fabric', 'status' } end
function M.svc_meta() return { 'svc', 'fabric', 'meta' } end
function M.cfg() return { 'cfg', 'fabric' } end

function M.state_root() return { 'state', 'fabric' } end
function M.state_link(link_id, ...)
  return append({ 'state', 'fabric', 'link', link_id }, ...)
end

function M.raw_source_meta(kind, source) return { 'raw', kind, source, 'meta' } end
function M.raw_source_status(kind, source) return { 'raw', kind, source, 'status' } end
function M.raw_source_state(kind, source, ...)
  return append({ 'raw', kind, source, 'state' }, ...)
end

function M.raw_member_meta(source) return M.raw_source_meta('member', source) end
function M.raw_member_status(source) return M.raw_source_status('member', source) end
function M.raw_member_state(source, ...) return M.raw_source_state('member', source, ...) end

function M.raw_cap_meta(kind, source, class, id)
  return { 'raw', kind, source, 'cap', class, id, 'meta' }
end
function M.raw_cap_status(kind, source, class, id)
  return { 'raw', kind, source, 'cap', class, id, 'status' }
end
function M.raw_cap_state(kind, source, class, id, ...)
  return append({ 'raw', kind, source, 'cap', class, id, 'state' }, ...)
end
function M.raw_cap_event(kind, source, class, id, ...)
  return append({ 'raw', kind, source, 'cap', class, id, 'event' }, ...)
end
function M.raw_cap_rpc(kind, source, class, id, method)
  return { 'raw', kind, source, 'cap', class, id, 'rpc', method }
end

function M.transfer_mgr_meta() return { 'cap', 'transfer-manager', 'main', 'meta' } end
function M.transfer_mgr_status() return { 'cap', 'transfer-manager', 'main', 'status' } end
function M.transfer_mgr_rpc(method) return { 'cap', 'transfer-manager', 'main', 'rpc', method } end
function M.transfer_mgr_event(name) return { 'cap', 'transfer-manager', 'main', 'event', name } end

return M
