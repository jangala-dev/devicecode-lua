-- services/update/topics.lua
--
-- Canonical Devicecode control-plane topics for the update service.

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

function M.svc_status() return { 'svc', 'update', 'status' } end
function M.svc_meta() return { 'svc', 'update', 'meta' } end
function M.cfg() return { 'cfg', 'update' } end

function M.manager_meta() return { 'cap', 'update-manager', 'main', 'meta' } end
function M.manager_status() return { 'cap', 'update-manager', 'main', 'status' } end
function M.manager_rpc(method) return { 'cap', 'update-manager', 'main', 'rpc', method } end
function M.manager_event(name) return { 'cap', 'update-manager', 'main', 'event', name } end

function M.ingest_meta() return { 'cap', 'artifact-ingest', 'main', 'meta' } end
function M.ingest_status() return { 'cap', 'artifact-ingest', 'main', 'status' } end
function M.ingest_rpc(method) return { 'cap', 'artifact-ingest', 'main', 'rpc', method } end
function M.ingest_event(name) return { 'cap', 'artifact-ingest', 'main', 'event', name } end

function M.workflow_job(id) return { 'state', 'workflow', 'update-job', id } end
function M.workflow_ingest(id) return { 'state', 'workflow', 'artifact-ingest', id } end

function M.summary() return { 'state', 'update', 'summary' } end
function M.component_summary(component) return { 'state', 'update', 'component', component } end

function M.append(base, ...) return append(base, ...) end

return M
