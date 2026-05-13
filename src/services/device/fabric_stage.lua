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
	if type(client) == 'table' and type(client.stage_source_op) == 'function' then
		return client:stage_source_op(source, meta, opts)
	end
	if type(client) == 'table' and type(client.send_source_op) == 'function' then
		return client:send_source_op(source, meta, opts)
	end
	if type(client) == 'function' then
		return client(source, meta, opts)
	end
	return nil, 'fabric_stage client does not provide send_blob_op'
end

local function is_op(v)
	return type(v) == 'table' and getmetatable(v) == op_mod.Op
end

local function copy_identity_metadata(dst, request)
	if type(dst) ~= 'table' or type(request) ~= 'table' then return dst end
	local metadata = request.metadata or request.meta
	if type(metadata) == 'table' then
		dst.version = dst.version or metadata.version
		dst.build = dst.build or metadata.build
		dst.build_id = dst.build_id or metadata.build_id
		dst.image_id = dst.image_id or metadata.image_id
	end
	dst.expected_image_id = dst.expected_image_id or request.expected_image_id
	if dst.image_id == nil then dst.image_id = request.expected_image_id end
	return dst
end

local function bool_field(t, ...)
	for i = 1, select('#', ...) do
		local k = select(i, ...)
		if t[k] ~= nil then return t[k] == true end
	end
	return nil
end

local function handoff_from_result(result)
	if type(result) ~= 'table' then
		return nil, 'fabric_stage result must be a table with explicit source ownership'
	end

	local h = result.source_handoff or result.handoff
	if h ~= nil and type(h) ~= 'table' then
		return nil, 'fabric_stage source_handoff must be a table'
	end

	local consumed
	local receiver_install

	if h then
		consumed = bool_field(h, 'consumed', 'consumed_source', 'source_consumed')
		receiver_install = h.receiver_install or h.install_receiver or h.install_receiver_termination
	else
		consumed = bool_field(result, 'consumed_source', 'source_consumed')
		receiver_install = result.receiver_install or result.install_receiver or result.install_receiver_termination
	end

	if consumed == nil then
		return nil, 'fabric_stage result must explicitly declare source_handoff/consumed_source'
	end

	if consumed ~= true then
		return { consumed = false, receiver_install = nil }, nil
	end

	if receiver_install ~= nil then
		if type(receiver_install) ~= 'function' then
			return nil, 'fabric_stage receiver termination installer must be a function'
		end
		return { consumed = true, receiver_install = receiver_install }, nil
	end

	-- Some clients perform the receiver-side termination ownership internally before
	-- returning. They must still say so explicitly; Device then turns that proof into
	-- the receiver_install callback used by resource.owned:handoff(...).
	local receiver_ready
	if h then
		receiver_ready = h.receiver_termination_installed == true or h.receiver_owns_source == true
	else
		receiver_ready = result.receiver_termination_installed == true or result.receiver_owns_source == true
	end

	if receiver_ready then
		return { consumed = true, receiver_install = function () return true end }, nil
	end

	return nil, 'fabric_stage consumed source without explicit receiver termination ownership'
end

local function map_result(result, perr)
	if result == nil then
		return nil, perr or 'fabric_stage_failed', nil
	end
	if type(result) == 'table' and result.ok == false then
		return nil, result.err or result.reason or 'fabric_stage_failed', nil
	end

	local handoff, herr = handoff_from_result(result)
	if not handoff then
		return nil, herr, nil
	end

	return result, nil, handoff
end

--- Stage a source through Fabric as an Op.
---
--- The Fabric client must return a table that explicitly states source ownership.
--- Preferred shape:
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
--- its local termination owner. If the receiver already installed termination internally,
--- it may instead return receiver_termination_installed=true or receiver_owns_source=true.
---
--- Return shape when performed:
---   result, nil, handoff_table
---   nil, err, nil
---
--- handoff_table.consumed=true means the source has been handed off and Device
--- must release its local termination only after handoff_table.receiver_install runs.
--- consumed=false means Device still owns termination.
function M.stage_source_op(_, params)
	params = params or {}
	local source = params.source
	if source == nil then
		return op_mod.always(nil, 'source_required', nil)
	end

	local request_payload = params.request_payload
	local transfer_meta = copy_identity_metadata({
		component = params.component,
		action = params.action,
		link_id = params.link_id,
		target = params.target,
		receiver = params.receiver,
		artifact_store = params.artifact_store,
		request = request_payload,
		chunk_size = params.chunk_size,
	}, request_payload)
	local ev, err = call_transfer_op(params.client or params.fabric_client, source, transfer_meta, {
		timeout = params.timeout,
		deadline = params.deadline,
		chunk_size = params.chunk_size,
	})

	if not ev then
		return op_mod.always(nil, err or 'fabric_stage_unavailable', nil)
	end

	if is_op(ev) then
		return ev:wrap(function (result, perr)
			return map_result(result, perr)
		end)
	end

	local mapped, merr, handoff = map_result(ev, nil)
	return op_mod.always(mapped, merr, handoff)
end


return M
