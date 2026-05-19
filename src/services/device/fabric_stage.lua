-- services/device/fabric_stage.lua
--
-- Fabric-stage client helper with explicit source-owner transfer.  Device opens
-- and owns the source; the Fabric client must either take that owner before
-- returning success, or leave it owned by Device on rejection/failure.

local op_mod = require 'fibers.op'

local M = {}

local function is_op(v)
	return type(v) == 'table' and getmetatable(v) == op_mod.Op
end

local function call_transfer_op(client, params, opts)
	if type(client) == 'table' and type(client.send_blob_op) == 'function' then
		return client:send_blob_op(params, opts)
	end
	return nil, 'fabric_stage client does not provide send_blob_op'
end

local function map_result(source_owner, result, perr)
	if result == nil then
		return nil, perr or 'fabric_stage_failed'
	end
	if type(result) == 'table' and result.ok == false then
		return nil, result.err or result.error or result.reason or 'fabric_stage_failed'
	end
	if source_owner and type(source_owner.is_owned) == 'function' and source_owner:is_owned() then
		return nil, 'fabric_stage client did not take source ownership'
	end
	return result, nil
end

--- Stage an owned source through Fabric as an Op.
---
--- The Fabric client must expose send_blob_op(params, opts). params.source_owner
--- is an owned finaliser-safe resource.  On success the client must have taken
--- ownership by detaching or handing off that owner.  On failure it must leave
--- ownership with the caller unless it has already accepted responsibility.
---
--- Return shape when performed:
---   result, nil
---   nil, err
function M.stage_source_op(_, params)
	params = params or {}
	local source_owner = params.source_owner
	if source_owner == nil or type(source_owner.value) ~= 'function' or type(source_owner.is_owned) ~= 'function' then
		return op_mod.always(nil, 'source_owner_required')
	end

	local payload = type(params.request_payload) == 'table' and params.request_payload or {}
	local transfer_meta = type(payload.meta) == 'table' and payload.meta or {
		kind = 'firmware',
		component = params.component,
		job_id = payload.job_id,
		image_id = payload.expected_image_id or payload.image_id,
		format = payload.format or 'dcmcu-v1',
	}

	local ev, err = call_transfer_op(params.client, {
		component = params.component,
		action = params.action,
		job_id = payload.job_id,
		request_id = payload.request_id,
		xfer_id = payload.xfer_id,
		link_id = params.link_id or payload.link_id,
		target = params.target or payload.target,
		size = payload.size,
		digest_alg = payload.digest_alg,
		digest = payload.digest,
		chunk_size = payload.chunk_size or params.chunk_size,
		meta = transfer_meta,
		source_owner = source_owner,
		artifact_store = params.artifact_store,
		request = payload,
	}, {
		timeout = params.timeout,
		deadline = params.deadline,
	})

	if not ev then
		return op_mod.always(nil, err or 'fabric_stage_unavailable')
	end

	if is_op(ev) then
		return ev:wrap(function (result, perr)
			return map_result(source_owner, result, perr)
		end)
	end

	return op_mod.always(map_result(source_owner, ev, nil))
end

return M
