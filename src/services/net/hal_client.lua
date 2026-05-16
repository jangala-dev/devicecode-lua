-- services/net/hal_client.lua
-- NET-facing semantic HAL client.
--
-- This module deliberately exposes product-level operations only.  NET callers
-- should not see host-specific command or configuration details here.

local op = require 'fibers.op'
local tablex = require 'shared.table'

local M = {}
local Client = {}
Client.__index = Client

local function copy(v)
	if type(v) == 'table' then return tablex.deep_copy(v) end
	return v
end

local function reason_text(reason, fallback)
	if type(reason) == 'table' then
		return tostring(reason.err or reason.reason or reason.message or reason.code or fallback)
	end
	if reason ~= nil then return tostring(reason) end
	return tostring(fallback)
end

local function failure_result(reason, fallback, code)
	local out = {
		ok = false,
		err = reason_text(reason, fallback or 'network HAL rejected request'),
		reason = copy(reason),
	}
	if code ~= nil then out.code = code end
	return out
end

local function reply_to_result(reply, err)
	if not reply then
		return failure_result(err, 'network HAL call failed')
	end

	if reply.ok ~= true then
		return failure_result(reply.reason, 'network HAL rejected request', reply.code)
	end

	if type(reply.reason) == 'table' then
		local out = copy(reply.reason)
		if out.ok == nil then out.ok = true end
		return out
	end

	return {
		ok = true,
		result = reply.reason,
	}
end

function M.new(conn, opts)
	opts = opts or {}
	return setmetatable({
		conn = conn,
		network_config = opts.network_config_cap,
		-- Dry-run must be explicit.  A missing network-config capability should not
		-- look like a successful host apply on production devices.
		dry_run = opts.dry_run == true,
	}, Client)
end

function Client:available()
	return self.network_config ~= nil
end

function Client:apply_intent_op(intent, opts)
	opts = opts or {}
	if self.network_config and type(self.network_config.call_control_op) == 'function' then
		return self.network_config:call_control_op('apply', {
			intent = intent,
			opts = opts,
		}, opts):wrap(reply_to_result)
	end

	if self.dry_run == true then
		return op.always({
			ok = true,
			applied = false,
			changed = false,
			backend = 'none',
			dry_run = true,
			note = 'network-config HAL capability not configured; explicit dry-run apply',
		})
	end

	return op.always({
		ok = false,
		err = 'network-config HAL capability not configured',
		reason = {
			code = 'missing_network_config_hal',
			detail = 'network-config HAL capability not configured',
		},
	})
end

return M
