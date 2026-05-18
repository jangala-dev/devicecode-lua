-- services/fabric/transfer_client.lua
--
-- Caller-side helper for one outbound Fabric byte transfer.

local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'
local sleep   = require 'fibers.sleep'

local queue    = require 'devicecode.support.queue'
local resource = require 'devicecode.support.resource'
local blob     = require 'devicecode.blob_source'
local protocol = require 'services.fabric.protocol'
local transfer = require 'services.fabric.transfer'
local contracts = require 'devicecode.support.contracts'

local M = {}

local function require_tx(v, name)
	return contracts.require_tx(v, name, 2)
end

local function pos_timeout(v)
	v = v or 30.0
	if type(v) ~= 'number' or v <= 0 then return nil, 'timeout' end
	return v, nil
end

local function source_owner(scope, p)
	if type(p.source_owner) == 'table' and type(p.source_owner.handoff) == 'function' then
		return p.source_owner, nil
	end

	local src = p.source
	if src == nil and type(p.data) == 'string' then
		src = blob.from_string(p.data)
	end
	if type(src) ~= 'table' or type(src.read_chunk_op) ~= 'function' then
		return nil, 'source_required'
	end

	local owner = resource.owned(src, {
		label = 'fabric transfer client source cleanup failed',
	})

	scope:finally(function (_, status, primary)
		owner:terminate_checked(primary or status or 'transfer client closed')
	end)

	return owner, nil
end

local function normalise_request(p)
	local id = p.request_id
	if type(id) ~= 'string' or id == '' then return nil, 'request_id_required' end
	if type(p.xfer_id) ~= 'string' or p.xfer_id == '' then return nil, 'xfer_id_required' end
	if type(p.target) ~= 'string' or p.target == '' then return nil, 'target_required' end

	local size = p.size
	if size == nil and type(p.data) == 'string' then size = #p.data end
	if type(size) ~= 'number' or size < 0 or size % 1 ~= 0 then
		return nil, 'size_required'
	end

	local digest_alg = p.digest_alg or protocol.DIGEST_ALG
	if digest_alg ~= protocol.DIGEST_ALG then return nil, 'unsupported_digest_alg' end

	local digest = p.digest
	if digest == nil and type(p.data) == 'string' then digest = protocol.digest_hex(p.data) end
	if type(digest) ~= 'string' or not protocol.digest_ok(digest) then
		return nil, 'digest_required'
	end

	return {
		request_id         = id,
		request_generation = p.request_generation or 1,
		xfer_id            = p.xfer_id,
		target             = p.target,
		size               = size,
		digest_alg         = digest_alg,
		digest             = digest,
		meta               = p.meta,
		chunk_size         = p.chunk_size,
	}, nil
end

local function remaining(deadline)
	local n = deadline - fibers.now()
	return n > 0 and n or 0
end

local function make_slot_request(req, reply_tx)
	local slot = {
		kind               = 'transfer_slot_request',
		request_id         = req.request_id,
		request_generation = req.request_generation,
		xfer_id            = req.xfer_id,
		target             = req.target,
		size               = req.size,
	}

	function slot:reply(value)
		return queue.try_admit_required(reply_tx, { ok = true, value = value },
			'transfer_client_slot_reply_failed')
	end

	function slot:fail(reason)
		return queue.try_admit_required(reply_tx, { ok = false, err = reason },
			'transfer_client_slot_fail_failed')
	end

	return slot
end

local function await_reply(rx, deadline, label)
	local which, reply = fibers.perform(fibers.named_choice {
		reply   = rx:recv_op(),
		timeout = sleep.sleep_op(remaining(deadline)),
	})

	if which == 'timeout' then return nil, 'timeout' end
	if reply == nil then return nil, label or 'closed' end
	if reply.ok ~= true then return nil, reply.err or label or 'failed' end
	return reply.value, nil
end

local function run_in_scope(scope, params)
	if type(params) ~= 'table' then error('transfer_client.run: params table required', 2) end

	local admission_tx = require_tx(params.admission_tx, 'transfer_client.run: admission_tx')
	local timeout_s, terr = pos_timeout(params.timeout_s)
	if not timeout_s then return nil, terr end

	local req, rerr = normalise_request(params)
	if not req then return nil, rerr end

	local owner, serr = source_owner(scope, params)
	if not owner then return nil, serr end

	local deadline = fibers.now() + timeout_s
	local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })

	scope:finally(function (_, status, primary)
		reply_tx:close(primary or status or 'transfer client closed')
	end)

	local ok, err = queue.try_admit_required(
		admission_tx,
		make_slot_request(req, reply_tx),
		'transfer_client_slot_request_failed'
	)
	if ok ~= true then return nil, err or 'slot_admission_failed' end

	local admitted, aerr = await_reply(reply_rx, deadline, 'slot_admission_closed')
	if not admitted then return nil, aerr end

	local lease = admitted.lease
	if type(lease) ~= 'table' or type(lease.start_attempt) ~= 'function' then
		return nil, 'slot_admission_missing_lease'
	end

	local lease_owner = resource.owned(lease, {
		terminate = function (value, reason) return value:release(reason) end,
		label = 'fabric transfer client lease release failed',
	})

	scope:finally(function (_, status, primary)
		lease_owner:terminate_checked(primary or status or 'transfer client closed')
	end)

	req.source_owner = owner
	req.timeout_s = timeout_s

	local handle, herr = transfer.start_attempt(scope, lease, req)
	if not handle then return nil, herr or 'transfer_attempt_start_failed' end

	local handed, handoff_err = lease_owner:handoff(function () return true end)
	if not handed then return nil, handoff_err or 'transfer_slot_lease_handoff_failed' end

	local which, ev = fibers.perform(fibers.named_choice {
		attempt = handle:outcome_op(),
		timeout = sleep.sleep_op(remaining(deadline)),
	})

	if which == 'timeout' then
		handle:cancel('timeout')
		return nil, 'timeout'
	end

	if ev == nil then return nil, 'attempt_outcome_missing' end
	if ev.status == 'ok' then return ev.result, nil end
	return nil, ev.primary or ev.status or 'transfer_attempt_failed'
end

function M.run(_, params)
	local st, _, result, err = fibers.run_scope(function (scope)
		return run_in_scope(scope, params)
	end)

	if st == 'ok' then return result, err end
	return nil, result or st or 'transfer_client_failed'
end

return M
