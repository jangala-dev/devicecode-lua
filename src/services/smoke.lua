-- services/smoke.lua
--
-- Hardware bring-up smoke tests for the devicecode-go MCU
-- protocol-alignment branch. Enable by setting
--   DEVICECODE_SERVICES=monitor,hal,config,fabric,smoke
-- and the service will, after the mcu0 fabric link reaches ready=true,
-- run scripted canary tests against the real MCU and print [smoke]
-- lines on stdout.
--
-- Tests
--   1. Push a HAL config to the MCU via `config/mcu` retain. The
--      fabric export rule maps it to `config/device` on the wire and
--      the MCU imports it as `config/hal`.
--   2. Call `rpc/peer/mcu-1/hal/dump` and check the reply.
--      `applied=true` plus a non-zero `config_count` confirms the
--      MCU received and applied the config from test 1.

local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'
local base    = require 'devicecode.service_base'

local M = {}

local LINK_ID = 'mcu0'
local LINK_TOPIC = { 'state', 'fabric', 'link', LINK_ID, 'session' }
local DUMP_TOPIC = { 'rpc', 'peer', 'mcu-1', 'hal', 'dump' }
local CFG_TOPIC = { 'config', 'mcu' }
local XFER_TOPIC = { 'cmd', 'fabric', 'transfer' }

local READY_TIMEOUT_S = 30
local DUMP_TIMEOUT_S = 2.0
local CFG_SETTLE_S = 2.0
local XFER_TIMEOUT_S = 30.0
local XFER_SIZE = 4 * 1024

local function log(line)
	io.write('[smoke] ', line, '\n')
	io.flush()
end

local function payload_brief(p)
	if type(p) ~= 'table' then return tostring(p) end
	local s = p.status
	if type(s) == 'table' then
		return string.format('kind=%s component=%s status.ready=%s status.established=%s status.peer_sid=%s',
			tostring(p.kind), tostring(p.component),
			tostring(s.ready), tostring(s.established), tostring(s.peer_sid))
	end
	return string.format('kind=%s component=%s ready=%s established=%s peer_sid=%s',
		tostring(p.kind), tostring(p.component),
		tostring(p.ready), tostring(p.established), tostring(p.peer_sid))
end

local function wait_for_ready(conn, timeout_s)
	local sub = conn:subscribe(LINK_TOPIC, { queue_len = 8, full = 'drop_oldest' })
	log('subscribed to ' .. table.concat(LINK_TOPIC, '/'))
	local deadline = runtime.now() + timeout_s
	while runtime.now() < deadline do
		local msg = sub:recv()
		if msg then
			-- Diagnostic: log every received link-state message so we can
			-- see exactly what the lua side publishes. Helpful when this
			-- service hangs at waiting_for_link despite the link being up.
			log('rx ' .. payload_brief(msg.payload))
			if type(msg.payload) == 'table' then
				-- statefmt.link_component wraps the snapshot under .status,
				-- but tolerate the un-wrapped shape too just in case.
				local status = msg.payload.status
				if type(status) == 'table' and status.ready == true then
					return true, status
				end
				if msg.payload.ready == true then
					return true, msg.payload
				end
			end
		end
	end
	return false, 'timeout waiting for link ready'
end

local function push_config(conn)
	conn:retain(CFG_TOPIC, {
		schema  = 'devicecode.config/hal/1',
		devices = {},
		pollers = {},
	})
end

local function call_dump(conn)
	local reply, err = conn:call(DUMP_TOPIC, {}, { timeout = DUMP_TIMEOUT_S })
	return reply, err
end

function M.start(conn, ctx)
	ctx = ctx or {}
	local svc = base.new(conn, { name = ctx.name or 'smoke', env = ctx.env })
	svc:status('running', { phase = 'waiting_for_link' })

	log('waiting for fabric link ' .. LINK_ID .. ' to reach ready...')
	local ok, info = wait_for_ready(conn, READY_TIMEOUT_S)
	if not ok then
		log('FAIL: ' .. tostring(info))
		svc:status('degraded', { reason = 'link_timeout' })
		return
	end
	log(string.format('link ready; peer_sid=%s peer_node=%s',
		tostring(info.peer_sid), tostring(info.peer_node)))

	log('test 1: pushing config/mcu retain (-> wire config/device -> MCU config/hal)')
	push_config(conn)
	sleep.sleep(CFG_SETTLE_S)

	log('test 2: calling rpc/peer/mcu-1/hal/dump')
	local reply, err = call_dump(conn)
	if err then
		log('test 2 FAIL: ' .. tostring(err))
		svc:status('degraded', { reason = 'rpc_failed', err = tostring(err) })
		return
	end
	if type(reply) ~= 'table' or not reply.ok then
		log('test 2 FAIL: bad reply: ' .. tostring(reply))
		svc:status('degraded', { reason = 'rpc_bad_reply' })
		return
	end
	log(string.format('test 2 reply: ok=%s applied=%s config_count=%s',
		tostring(reply.ok), tostring(reply.applied), tostring(reply.config_count)))

	local applied = reply.applied
	local count = tonumber(reply.config_count) or 0
	if not (applied and count > 0) then
		log('test 2 INCOMPLETE: config did not reach MCU per dump reply')
		svc:status('degraded', { reason = 'config_not_applied' })
		while true do sleep.sleep(60) end
	end

	-- Test 3: drive a synthetic transfer end-to-end. Exercises the W2
	-- transfer wire schema (xfer_begin/chunk/need/commit/done/abort), W3
	-- idle-chunk watchdog, W5 bulk-lane scheduling, and W8 GC fix on the
	-- MCU side. The default protocol-baseline MCU build rejects
	-- transfers at xfer_begin (errTransferUnsupported -> xfer_abort with
	-- err="staging_unavailable: ..."), so success here is an EXPECTED
	-- abort reply, not a delivered blob. Build the MCU with
	-- `-tags "pico_bb_proto_1 flash_unsafe"` to take the abupdate path
	-- and see the success branch instead.
	log(string.format('test 3: sending synthetic %d-byte transfer to %s', XFER_SIZE, LINK_ID))
	local payload = string.rep('A', XFER_SIZE)
	local xreply, xerr = conn:call(XFER_TOPIC, {
		link_id = LINK_ID,
		op = 'send_blob',
		source = payload,
		meta = { kind = 'smoke-test' },
	}, { timeout = XFER_TIMEOUT_S })

	if xerr then
		log(string.format('test 3 result: err=%s (this is expected for the safe-sink build)', tostring(xerr)))
	elseif type(xreply) == 'table' and xreply.ok then
		log(string.format('test 3 OK: xfer_id=%s size=%s checksum=%s',
			tostring(xreply.xfer_id), tostring(xreply.size), tostring(xreply.checksum)))
	else
		log(string.format('test 3 unexpected reply: %s', tostring(xreply)))
	end

	log('all tests done')
	svc:status('running', { phase = 'tests_done', config_count = count })

	-- Idle forever; exiting would propagate as a service failure.
	while true do sleep.sleep(60) end
end

return M
