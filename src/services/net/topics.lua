-- services/net/topics.lua
-- Public topic vocabulary owned by the NET service.

local M = {}

local function token(v)
	local s = tostring(v or '')
	s = s:gsub('[^%w%._%-]', '_')
	if s == '' then s = 'unknown' end
	return s
end

function M.config() return { 'cfg', 'net' } end
function M.summary() return { 'state', 'net', 'summary' } end
function M.apply() return { 'state', 'net', 'apply' } end
function M.segment(id) return { 'state', 'net', 'segment', token(id) } end
function M.interface(id) return { 'state', 'net', 'interface', token(id) } end
function M.domain(name) return { 'state', 'net', token(name) } end
function M.event(name) return { 'event', 'net', token(name) } end
function M.rpc(method) return { 'net', 'rpc', token(method) } end

M._test = { token = token }

return M
