-- services/fabric/reader.lua
--
-- Inbound framed transport reader.
--
-- Responsibilities:
--   * read framed lines from the transport
--   * decode and validate protocol frames
--   * classify frames into control / rpc / transfer lanes
--   * emit rx activity to the session controller
--
-- This module does not interpret session state or business policy.

local fibers   = require 'fibers'
local protocol = require 'services.fabric.protocol'
local runtime  = require 'fibers.runtime'

local M = {}

local function send_or_fail(tx, value, what)
	local ok, reason = tx:send(value)
	if ok ~= true then
		error((what or 'mailbox_send_failed') .. ': ' .. tostring(reason or 'closed'), 0)
	end
end

function M.run(ctx)
	local transport = assert(ctx.transport, 'reader requires transport')
	local control_tx = assert(ctx.control_tx, 'reader requires control_tx')
	local rpc_tx = assert(ctx.rpc_tx, 'reader requires rpc_tx')
	local xfer_tx = assert(ctx.xfer_tx, 'reader requires xfer_tx')
	local status_tx = assert(ctx.status_tx, 'reader requires status_tx')
	local bad_limit = tonumber(ctx.bad_frame_limit) or 5
	local bad_window = tonumber(ctx.bad_frame_window_s) or 10.0
	local svc = ctx.svc

	local bad_count = 0
	local bad_window_start = runtime.now()

	local function note_bad(err, line)
		local now = runtime.now()
		if now - bad_window_start > bad_window then
			bad_window_start = now
			bad_count = 0
		end

		bad_count = bad_count + 1

		if svc then
			svc:obs_log('warn', {
				what = 'fabric_bad_frame',
				link_id = ctx.link_id,
				err = tostring(err),
				count = bad_count,
				line = line,
			})
		end

		if bad_count >= bad_limit then
			error('too_many_bad_frames', 0)
		end
	end

	while true do
		local line, err = fibers.perform(transport:read_line_op(ctx.read_timeout_s))
		if not line then
			if err ~= 'timeout' then
				error('transport_read_failed: ' .. tostring(err), 0)
			end
		else
			local msg, derr = protocol.decode_line(line)
			if not msg then
				note_bad(derr, line)
			else
				local now = runtime.now()
				send_or_fail(status_tx, { kind = 'rx_activity', at = now }, 'status_overflow')

				local item = { msg = msg, at = now }
				local class = protocol.classify(msg)

				if class == 'rpc' then
					send_or_fail(rpc_tx, item, 'rpc_in_overflow')

				elseif class == 'bulk' then
					send_or_fail(xfer_tx, item, 'xfer_in_overflow')

				elseif class == 'control' then
					-- Fabric uses a narrower "control" lane than protocol.classify():
					-- session control frames stay on control_tx, but transfer protocol
					-- control frames are owned by transfer_mgr and therefore flow on xfer_tx.
					if msg.type and msg.type:match('^xfer_') then
						send_or_fail(xfer_tx, item, 'xfer_in_overflow')
					else
						send_or_fail(control_tx, item, 'control_in_overflow')
					end

				else
					note_bad('unknown_class', line)
				end
			end
		end
	end
end

return M
