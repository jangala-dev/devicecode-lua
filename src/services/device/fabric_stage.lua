-- services/device/fabric_stage.lua
--
-- Fabric-stage client helper with explicit source-ownership contract.
-- This module does not implement Fabric internals. It wraps an injected client
-- whose send_blob_op/source handoff contract is documented at the call site.

local op_mod = require 'fibers.op'

local M = {}

local function call_transfer_op(client, source, meta, opts)
	if type(client) == 'table' and type(client.send_blob_op) == 'function' then
		return client:send_blob_op(source, meta, opts)
	end
	return nil, 'fabric_stage client does not provide send_blob_op'
end

local function is_op(v)
	return type(v) == 'table' and getmetatable(v) == op_mod.Op
end

local function handoff_from_result(result)
	if type(result) ~= 'table' then
		return nil, 'fabric_stage result must be a table with explicit source_handoff'
	end

	local h = result.source_handoff
	if type(h) ~= 'table' then
		return nil, 'fabric_stage result must include source_handoff table'
	end

	local consumed = h.consumed
	if type(consumed) ~= 'boolean' then
		return nil, 'fabric_stage source_handoff.consumed must be boolean'
	end
	if consumed ~= true then
		return { consumed = false, receiver_install = nil }, nil
	end

	if type(h.receiver_install) ~= 'function' then
		return nil, 'fabric_stage source_handoff receiver termination proof requires receiver_install function when consumed is true'
	end

	return { consumed = true, receiver_install = h.receiver_install }, nil
end

local function map_result(result, perr)
	if result == nil then
		return nil, perr or 'fabric_stage_failed', nil
	end
	if type(result) == 'table' and result.ok == false then
		return nil, result.err or 'fabric_stage_failed', nil
	end

	local handoff, herr = handoff_from_result(result)
	if not handoff then
		return nil, herr, nil
	end

	return result, nil, handoff
end

--- Stage a source through Fabric as an Op.
---
--- The Fabric client must expose send_blob_op(source, meta, opts) and return a
--- table that explicitly states source ownership in exactly this shape:
---
---   {
---     ok = true,
---     source_handoff = {
---       consumed = true,
---       receiver_install = function(source) ... end,
---     },
---   }
---
--- `receiver_install(source)` is called by Device immediately before it releases
--- its local termination owner. If consumed=false, Device retains ownership of
--- source termination.
---
--- Return shape when performed:
---   result, nil, handoff_table
---   nil, err, nil
function M.stage_source_op(_, params)
	params = params or {}
	local source = params.source
	if source == nil then
		return op_mod.always(nil, 'source_required', nil)
	end

	local ev, err = call_transfer_op(params.client, source, {
		component = params.component,
		action = params.action,
		link_id = params.link_id,
		receiver = params.receiver,
		artifact_store = params.artifact_store,
		request = params.request_payload,
	}, {
		timeout = params.timeout,
		deadline = params.deadline,
	})

	if not ev then
		return op_mod.always(nil, err or 'fabric_stage_unavailable', nil)
	end

	if is_op(ev) then
		return ev:wrap(map_result)
	end

	return op_mod.always(map_result(ev, nil))
end

return M
