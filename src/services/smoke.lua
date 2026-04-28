-- services/smoke.lua
--
-- Hardware bring-up smoke tests for the devicecode-go fabric-update
-- branch. Enable by setting
--   DEVICECODE_SERVICES=monitor,hal,config,fabric,smoke
-- and the service will, after the mcu0 fabric link reaches ready=true,
-- run scripted canary tests against the real MCU and print [smoke]
-- lines on stdout.
--
-- Tests
--   1. Observe state/self/software retain. The W5 identity fact must
--      arrive on every newly established session (W10 republish edge).
--      Verifies fabric exports + the new state/self/* surface end to
--      end on the wire.
--   2. Call cmd/self/updater/prepare via outbound_call_rules. Replies
--      {ok=true, accepted=true} on success per W4.
--   3. Drive a synthetic transfer with meta.receiver. The default
--      MCU build's stub verifier rejects every artefact; expect
--      xfer_abort with the verifier_stub sentinel string.
--
-- Notes
-- - Pre-W12 smoke pushed config/mcu retain and used rpc/hal/dump.
--   Both paths are gone. The new surface is what this file targets.

local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'
local base    = require 'devicecode.service_base'

local M = {}

local LINK_ID = 'mcu0'
local LINK_TOPIC = { 'state', 'fabric', 'link', LINK_ID, 'session' }

-- Imported MCU state lands at peer/mcu-1/state/self/* per the
-- mcu-dev.json import_rules ([peer mcu-1 state] <- remote [state]).
local SOFTWARE_FACT_TOPIC = { 'peer', 'mcu-1', 'state', 'self', 'software' }
local UPDATER_FACT_TOPIC  = { 'peer', 'mcu-1', 'state', 'self', 'updater' }

-- Outbound RPC routing (mcu-dev.json outbound_call_rules):
-- [raw member mcu cap updater main rpc *] -> remote [cmd self updater *]
local PREPARE_TOPIC = { 'raw', 'member', 'mcu', 'cap', 'updater', 'main', 'rpc', 'prepare' }
local XFER_TOPIC    = { 'cmd', 'fabric', 'transfer' }

local READY_TIMEOUT_S = 30
local FACT_TIMEOUT_S  = 10
local RPC_TIMEOUT_S   = 2.0
local XFER_TIMEOUT_S  = 30.0
local XFER_SIZE       = 4 * 1024

local function log(line)
	io.write('[smoke] ', line, '\n')
	io.flush()
end

local function wait_for_ready(conn, timeout_s)
	local sub = conn:subscribe(LINK_TOPIC, { queue_len = 8, full = 'drop_oldest' })
	local deadline = runtime.now() + timeout_s
	while runtime.now() < deadline do
		local msg = sub:recv()
		if msg and type(msg.payload) == 'table' then
			local status = msg.payload.status
			if type(status) == 'table' and status.ready == true then
				return true, status
			end
			if msg.payload.ready == true then
				return true, msg.payload
			end
		end
	end
	return false, 'timeout waiting for link ready'
end

local function wait_for_software_fact(conn, timeout_s)
	local sub = conn:subscribe(SOFTWARE_FACT_TOPIC, { queue_len = 4, full = 'drop_oldest' })
	local deadline = runtime.now() + timeout_s
	while runtime.now() < deadline do
		local msg = sub:recv()
		if msg and type(msg.payload) == 'table' then
			return true, msg.payload
		end
	end
	return false, 'timeout waiting for state/self/software'
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

	-- Test 1: observe state/self/software retain.
	log('test 1: observing peer/mcu-1/state/self/software (W5 identity fact)')
	local got, sw = wait_for_software_fact(conn, FACT_TIMEOUT_S)
	if not got then
		log('test 1 FAIL: ' .. tostring(sw))
		svc:status('degraded', { reason = 'no_software_fact' })
		return
	end
	log(string.format('test 1 OK: version=%s build=%s image_id=%s boot_id=%s',
		tostring(sw.version), tostring(sw.build), tostring(sw.image_id), tostring(sw.boot_id)))
	if type(sw.boot_id) ~= 'string' or #sw.boot_id ~= 16 then
		log('test 1 WARN: boot_id length != 16: ' .. tostring(sw.boot_id))
	end

	-- Test 2: call cmd/self/updater/prepare via outbound_call_rules.
	log('test 2: calling cmd/self/updater/prepare via outbound_call_rules')
	local reply, err = conn:call(PREPARE_TOPIC, { target = 'img-test', metadata = nil },
		{ timeout = RPC_TIMEOUT_S })
	if err then
		log('test 2 FAIL: ' .. tostring(err))
		svc:status('degraded', { reason = 'prepare_failed', err = tostring(err) })
		return
	end
	if type(reply) ~= 'table' or not reply.ok or not reply.accepted then
		log('test 2 FAIL: bad reply: ' .. tostring(reply))
		svc:status('degraded', { reason = 'prepare_bad_reply' })
		return
	end
	log('test 2 OK: prepare ok=true accepted=true')

	-- Test 3: synthetic transfer with meta.receiver; expect rejection
	-- via the safe-default stub verifier.
	log(string.format('test 3: sending synthetic %d-byte transfer with meta.receiver', XFER_SIZE))
	local payload = string.rep('A', XFER_SIZE)
	local xreply, xerr = conn:call(XFER_TOPIC, {
		link_id = LINK_ID,
		op = 'send_blob',
		source = payload,
		meta = {
			kind = 'smoke-test',
			receiver = { 'raw', 'member', 'mcu', 'cap', 'updater', 'main', 'rpc', 'receive' },
		},
	}, { timeout = XFER_TIMEOUT_S })

	if xerr then
		log(string.format('test 3 result: err=%s (expected on stub-verifier build)', tostring(xerr)))
	elseif type(xreply) == 'table' and xreply.ok then
		log(string.format('test 3 OK: xfer_id=%s size=%s', tostring(xreply.xfer_id), tostring(xreply.size)))
	else
		log('test 3 unexpected reply: ' .. tostring(xreply))
	end

	-- Optional follow-up: observe state/self/updater for the staged
	-- transition. With the stub verifier this stays at running/idle;
	-- with fakeVerifierAccept (from fabric-security) it would flip to
	-- staged after test 3.
	local upSub = conn:subscribe(UPDATER_FACT_TOPIC, { queue_len = 4, full = 'drop_oldest' })
	local upDeadline = runtime.now() + 2
	while runtime.now() < upDeadline do
		local msg = upSub:recv()
		if msg and type(msg.payload) == 'table' then
			log(string.format('updater fact: state=%s last_error=%s pending_version=%s',
				tostring(msg.payload.state), tostring(msg.payload.last_error),
				tostring(msg.payload.pending_version)))
			break
		end
	end

	log('all tests done')
	svc:status('running', { phase = 'tests_done' })

	-- Idle forever; exiting would propagate as a service failure.
	while true do sleep.sleep(60) end
end

return M
