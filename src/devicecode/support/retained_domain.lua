-- devicecode/support/retained_domain.lua
--
-- Tiny retained domain-state owner.  This is intentionally not a model
-- framework: it is a non-yielding publication helper for older services while
-- they move towards the service-architecture.md coordinator/model style.
--
-- Doctrine:
--   * retained state/<domain>/... means this domain fact is currently asserted;
--   * unretain removes facts that are no longer asserted;
--   * clear() is suitable for scope finalisers and must never wait.

local bus_cleanup = require 'devicecode.support.bus_cleanup'
local retained_publish = require 'devicecode.support.retained_publish'
local tablex = require 'shared.table'

local M = {}
local Domain = {}
Domain.__index = Domain

local function copy(v) return tablex.deep_copy(v) end

local function topic_key(topic)
	local out = {}
	for i = 1, #(topic or {}) do out[i] = tostring(topic[i]) end
	return table.concat(out, '/')
end

local function join_topic(prefix, rel)
	local out = {}
	for i = 1, #(prefix or {}) do out[#out + 1] = prefix[i] end
	if type(rel) == 'table' then
		for i = 1, #rel do out[#out + 1] = rel[i] end
	elseif rel ~= nil then
		out[#out + 1] = rel
	end
	return out
end

function M.new(conn, opts)
	opts = opts or {}
	local prefix = copy(opts.prefix or {})
	return setmetatable({
		conn = conn,
		prefix = prefix,
		cache = {},
		owned = {},
		opts = opts.opts,
	}, Domain)
end

function Domain:topic(rel)
	return join_topic(self.prefix, rel)
end

function Domain:retain(rel, payload, opts)
	local topic = self:topic(rel)
	local key = topic_key(topic)
	local ok, err, changed = retained_publish.retain_if_changed(self.conn, self.cache, key, topic, payload, opts or self.opts)
	if ok == true then self.owned[key] = topic end
	return ok, err, changed
end

function Domain:unretain(rel, opts)
	local topic = self:topic(rel)
	local key = topic_key(topic)
	local ok, err = bus_cleanup.unretain(self.conn, topic, opts or self.opts)
	if ok ~= true then return nil, err, false end
	self.owned[key] = nil
	self.cache[key] = nil
	return true, nil, true
end

function Domain:clear(opts)
	local keys = {}
	for key in pairs(self.owned) do keys[#keys + 1] = key end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local topic = self.owned[key]
		bus_cleanup.unretain(self.conn, topic, opts or self.opts)
		self.owned[key] = nil
		self.cache[key] = nil
	end
	return true, nil
end

M.Domain = Domain
return M
