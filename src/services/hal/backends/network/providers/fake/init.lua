-- services/hal/backends/network/providers/fake/init.lua
-- In-memory semantic network provider for tests and initial service wiring.

local op = require 'fibers.op'
local tablex = require 'shared.table'

local M = {}
local Provider = {}
Provider.__index = Provider

local function copy(v) return tablex.deep_copy(v) end

function M.new(config, _opts)
	return setmetatable({
		config = copy(config or {}),
		last_intent = nil,
		terminated = nil,
	}, Provider), nil
end

function Provider:validate_op(req)
	return op.always({ ok = true, valid = true, checked = true, request = copy(req or {}) })
end

function Provider:plan_op(req)
	return op.always({
		ok = true,
		plan = {
			backend = 'fake',
			intent = copy(req and req.intent or req),
			steps = {},
		},
	})
end

function Provider:apply_op(req)
	local intent = req and (req.intent or req.desired or req)
	self.last_intent = copy(intent)
	return op.always({
		ok = true,
		applied = true,
		changed = true,
		backend = 'fake',
		intent_rev = intent and intent.rev or nil,
	})
end

function Provider:snapshot_op(_req)
	return op.always({
		ok = true,
		backend = 'fake',
		last_intent = copy(self.last_intent),
	})
end

function Provider:probe_link_op(req)
	return op.always({
		ok = true,
		backend = 'fake',
		link_id = req and req.link_id or nil,
		state = 'unknown',
	})
end

function Provider:read_counters_op(req)
	return op.always({
		ok = true,
		backend = 'fake',
		links = {},
		request = copy(req or {}),
	})
end

function Provider:terminate(reason)
	self.terminated = reason or true
	return true, nil
end

return M
