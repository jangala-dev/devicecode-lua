-- services/device/fabric_transfer_client.lua
--
-- Device-side adapter for the Fabric transfer-manager bus API.

local op = require 'fibers.op'
local fabric_topics = require 'services.fabric.topics'
local fabric_protocol = require 'services.fabric.protocol'

local M = {}

local function source_desc(source)
	if type(source) ~= 'table' then return {} end
	if type(source._artifact_desc) == 'table' then return source._artifact_desc end
	if type(source.describe) == 'function' then
		local ok, desc = pcall(function () return source:describe() end)
		if ok and type(desc) == 'table' then return desc end
	end
	return {}
end

local function transfer_request(source, meta, opts)
	meta = meta or {}
	opts = opts or {}

	local desc = source_desc(source)
	local request = type(meta.request) == 'table' and meta.request or {}
	local source_size = type(source) == 'table' and source.size or nil
	local source_digest = type(source) == 'table' and source.digest or nil
	local source_digest_alg = type(source) == 'table' and source.digest_alg or nil

	local req = {
		source = source,
		link_id = meta.link_id,
		request_id = request.request_id or request.job_id,
		target = meta.target,
		size = meta.size or request.size or source_size or desc.size,
		digest_alg = meta.digest_alg or request.digest_alg or source_digest_alg or fabric_protocol.DIGEST_ALG,
		digest = meta.digest or request.digest or source_digest or desc.checksum,
		timeout_s = opts.timeout_s or meta.timeout_s or request.timeout_s or opts.timeout,
		meta = meta,
	}

	if type(req.target) ~= 'string' or req.target == '' then
		return nil, 'transfer_target_required'
	end
	if type(req.size) ~= 'number' or req.size < 0 or req.size % 1 ~= 0 then
		return nil, 'artifact_size_required'
	end
	if req.digest_alg ~= fabric_protocol.DIGEST_ALG
		or type(req.digest) ~= 'string'
		or not fabric_protocol.digest_ok(req.digest)
	then
		return nil, 'artifact_digest_required'
	end

	return req, nil
end

local function transfer_result(reply, err)
	if reply == nil then return nil, err end
	if type(reply) == 'table' and reply.ok == false then
		return nil, reply.err or reply.error or reply.reason or 'transfer_failed'
	end

	local result = type(reply) == 'table' and (reply.result or reply) or reply
	return {
		ok = true,
		transfer = result,
		reply_payload = {
			staged = true,
			transfer = result,
		},
		source_handoff = {
			consumed = true,
			receiver_termination_installed = true,
		},
	}, nil
end

function M.new(conn)
	if type(conn) ~= 'table' or type(conn.call_op) ~= 'function' then
		return nil
	end

	return {
		send_blob_op = function (_, source, meta, opts)
			local req, err = transfer_request(source, meta, opts)
			if not req then return op.always(nil, err) end

			return conn:call_op(fabric_topics.transfer_manager_rpc('send-blob'), req, {
				timeout = opts and opts.timeout,
				deadline = opts and opts.deadline,
			}):wrap(transfer_result)
		end,
	}
end

return M
