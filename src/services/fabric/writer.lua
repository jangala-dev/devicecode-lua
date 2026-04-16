-- services/fabric/writer.lua

local fibers   = require 'fibers'
local protocol = require 'services.fabric.protocol'
local runtime  = require 'fibers.runtime'
local wait     = require 'fibers.wait'

local M = {}

local function send_status(tx, item)
	local ok, reason = tx:send(item)
	if ok ~= true then
		error('writer status mailbox failed: ' .. tostring(reason or 'closed'), 0)
	end
end

local function has_item(rx)
	local st = rx and rx._st
	if not st then return false end
	if st.closed then return true end
	if st.buf and st.buf:length() > 0 then return true end
	if st.putq and not st.putq:empty() then return true end
	return false
end

function M.run(ctx)
	local transport = assert(ctx.transport, 'writer requires transport')
	local tx_control = assert(ctx.tx_control, 'writer requires tx_control')
	local tx_rpc = assert(ctx.tx_rpc, 'writer requires tx_rpc')
	local tx_bulk = assert(ctx.tx_bulk, 'writer requires tx_bulk')
	local status_tx = assert(ctx.status_tx, 'writer requires status_tx')

	local rpc_quota = tonumber(ctx.rpc_quota or ctx.rpc_quantum) or 4
	local bulk_quota = tonumber(ctx.bulk_quota or ctx.bulk_quantum) or 1
	local turn = 'rpc'
	local quota_left = rpc_quota

	local function write_item(item)
		local line = item.line
		if not line then
			line = assert(protocol.encode_line(item.frame))
		end
		local ok, err = fibers.perform(transport:write_line_op(line))
		if not ok then
			error('transport_write_failed: ' .. tostring(err), 0)
		end
		send_status(status_tx, { kind = 'tx_activity', at = runtime.now() })
	end

	local function recv_now(rx)
		local item, err = rx:recv()
		if not item then
			error('writer outbound queue closed: ' .. tostring(err), 0)
		end
		return item
	end

	local function choose_non_control_rx()
		local rpc_ready = has_item(tx_rpc)
		local bulk_ready = has_item(tx_bulk)
		if rpc_ready and not bulk_ready then return tx_rpc end
		if bulk_ready and not rpc_ready then return tx_bulk end
		if not rpc_ready and not bulk_ready then return nil end

		if turn == 'rpc' then
			if quota_left <= 0 then
				turn = 'bulk'
				quota_left = bulk_quota
			end
			if rpc_ready then
				quota_left = quota_left - 1
				return tx_rpc
			end
			turn = 'bulk'
			quota_left = bulk_quota - 1
			return tx_bulk
		else
			if quota_left <= 0 then
				turn = 'rpc'
				quota_left = rpc_quota
			end
			if bulk_ready then
				quota_left = quota_left - 1
				return tx_bulk
			end
			turn = 'rpc'
			quota_left = rpc_quota - 1
			return tx_rpc
		end
	end

	local function choose_ready_rx()
		if has_item(tx_control) then return tx_control end
		return choose_non_control_rx()
	end

	local function wait_any_queue_op()
		local function register(task, waker)
			local t1 = tx_control:on_message(task, waker)
			local t2 = tx_rpc:on_message(task, waker)
			local t3 = tx_bulk:on_message(task, waker)
			return {
				unlink = function()
					if t1 and t1.unlink then t1:unlink() end
					if t2 and t2.unlink then t2:unlink() end
					if t3 and t3.unlink then t3:unlink() end
					return false
				end,
			}
		end

		local function probe_step()
			local chosen = choose_ready_rx()
			if chosen then return true, chosen end
			return false
		end

		return wait.waitable2(register, probe_step, probe_step)
	end

	while true do
		local chosen = choose_ready_rx()
		if not chosen then
			chosen = fibers.perform(wait_any_queue_op())
			chosen = choose_ready_rx() or chosen
		end
		write_item(recv_now(chosen))
	end
end

return M
