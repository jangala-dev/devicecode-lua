-- services/hal/backends/network/providers/openwrt/shaper.lua
-- Dispatcher for Devicecode OpenWrt shaping link kinds.

local u32_shaper = require 'services.hal.backends.network.providers.openwrt.tc_u32_shaper'
local mark_shaper = require 'services.hal.backends.network.providers.openwrt.tc_mark_shaper'
local shaping_marks = require 'services.hal.backends.network.providers.openwrt.shaping_marks'

local M = {}
local function is_plain_table(x) return type(x) == 'table' and getmetatable(x) == nil end
local function copy(v) if type(v) ~= 'table' then return v end local o = {}; for k,val in pairs(v) do o[k]=copy(val) end; return o end
local function sorted_keys(t) local ks={}; for k in pairs(t or {}) do ks[#ks+1]=k end; table.sort(ks,function(a,b)return tostring(a)<tostring(b)end); return ks end

function M.apply(req, opts)
	req = req or {}; opts = opts or {}
	local link_map = req.links or req.policy
	if not is_plain_table(link_map) then
		return u32_shaper.apply(req, opts)
	end
	local u32_req = copy(req); u32_req.links = {}
	local mark_req = { enabled = true, links = {}, marks = copy(req.marks or shaping_marks.default_marks()) }
	local reported = {}
	for _, id in ipairs(sorted_keys(link_map)) do
		local link = link_map[id]
		if is_plain_table(link) then
			if link.kind == 'wan_mark' then
				mark_req.links[id] = copy(link)
			else
				u32_req.links[id] = copy(link)
			end
		end
	end
	local changed = false
	if next(mark_req.links) ~= nil then
		local mr = shaping_marks.apply(mark_req, opts)
		if not mr or mr.ok ~= true then return { ok = false, err = 'shaping marks: ' .. tostring(mr and mr.err or 'failed'), backend = 'openwrt' } end
		local tr = mark_shaper.apply(mark_req, opts)
		if not tr or tr.ok ~= true then return tr or { ok = false, err = 'wan mark shaper failed', backend = 'openwrt' } end
		for k,v in pairs(tr.links or {}) do reported[k]=v end
		changed = changed or tr.changed == true or mr.applied == true
	end
	if next(u32_req.links) ~= nil then
		local ur = u32_shaper.apply(u32_req, opts)
		if not ur or ur.ok ~= true then return ur or { ok = false, err = 'u32 shaper failed', backend = 'openwrt' } end
		for k,v in pairs(ur.links or {}) do reported[k]=v end
		changed = changed or ur.changed == true
	end
	return { ok = true, applied = true, changed = changed, backend = 'openwrt', links = reported }
end

return M
