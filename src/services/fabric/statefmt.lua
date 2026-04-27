-- services/fabric/statefmt.lua
--
-- Shared retained-state envelope helpers for fabric.
--
-- These are intentionally dumb formatters:
--   * no ownership decisions
--   * no lifecycle policy
--   * no cross-component interpretation
--
-- Per-link component subtrees all use the same payload shape:
--   {
--     kind = 'fabric.link.<component>',
--     link_id = <id>,
--     component = <component>,
--     ts = <monotonic seconds>,
--     status = { ... component-specific fields ... },
--   }

local runtime = require 'fibers.runtime'

local M = {}

local function shallow_copy(t)
	local out = {}
	if t then
		for k, v in pairs(t) do
			out[k] = v
		end
	end
	return out
end

function M.component_topic(link_id, component)
	return { 'state', 'fabric', 'link', link_id, component }
end

function M.link_component(component, link_id, status, extra)
	local payload = {
		kind = 'fabric.link.' .. tostring(component),
		link_id = link_id,
		component = component,
		ts = runtime.now(),
		status = shallow_copy(status),
	}

	if extra then
		for k, v in pairs(extra) do
			payload[k] = v
		end
	end

	return payload
end

function M.summary(status, links, extra)
	local payload = {
		kind = 'fabric.summary',
		component = 'summary',
		ts = runtime.now(),
		status = shallow_copy(status),
		links = shallow_copy(links),
	}

	if extra then
		for k, v in pairs(extra) do
			payload[k] = v
		end
	end

	return payload
end

return M
