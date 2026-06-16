-- services/wired/topics.lua
-- Public topic vocabulary owned by the Wired service.

local M = {}

local function token(v)
	local s = tostring(v or '')
	s = s:gsub('[^%w%._%-]', '_')
	if s == '' then s = 'unknown' end
	return s
end

function M.config() return { 'cfg', 'wired' } end
function M.summary() return { 'state', 'wired', 'summary' } end
function M.surface(id) return { 'state', 'wired', 'surface', token(id) } end
function M.provider(id) return { 'state', 'wired', 'provider', token(id) } end
function M.topology() return { 'state', 'wired', 'topology' } end
function M.violations() return { 'state', 'wired', 'violations' } end
function M.event(name) return { 'event', 'wired', token(name) } end

function M.net_segments() return { 'state', 'net', 'segments' } end
function M.device_assembly() return { 'state', 'device', 'assembly' } end
function M.raw_wired_provider_pattern() return { 'raw', 'host', 'wired', 'provider', '#' } end

M._test = { token = token }

return M
