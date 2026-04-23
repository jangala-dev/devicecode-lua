-- services/ui/queries.lua
--
-- Pure read-model projections over the UI model.
--
-- These helpers do not perform authentication or transport work; handlers are
-- expected to do that first.

local errors = require 'services.ui.errors'

local M = {}

local function by_name(entries, idx)
	local out = {}
	for i = 1, #(entries or {}) do
		local rec = entries[i]
		local topic = rec and rec.topic or nil
		local name = type(topic) == 'table' and topic[idx] or nil
		if type(name) == 'string' and name ~= '' then
			out[name] = rec.payload
		end
	end
	return out
end


local function require_name(value, name)
	if type(value) ~= 'string' or value == '' then
		return nil, errors.bad_request((name or 'value') .. ' must be a non-empty string')
	end
	return value, nil
end

function M.config_get(model, service_name)
	local svc, err = require_name(service_name, 'service_name')
	if not svc then return nil, err end

	local rec, gerr = model:get_exact({ 'cfg', svc })
	if not rec then return nil, gerr end
	return rec.payload, nil
end

function M.service_status(model, service_name)
	local svc, err = require_name(service_name, 'service_name')
	if not svc then return nil, err end

	local rec, serr = model:get_exact({ 'svc', svc, 'status' })
	if not rec then return nil, serr end
	return rec.payload, nil
end

-- Merge service announce/status projections keyed by service name.
function M.services_snapshot(model)
	local ann, aerr = model:snapshot({ 'svc', '+', 'announce' })
	if not ann then return nil, aerr end

	local st, serr = model:snapshot({ 'svc', '+', 'status' })
	if not st then return nil, serr end

	return {
		seq = math.max(ann.seq, st.seq),
		announce = by_name(ann.entries, 2),
		status = by_name(st.entries, 2),
	}, nil
end

-- Aggregate fabric summary plus per-link component views.
function M.fabric_status(model)
	local main, merr = model:get_exact({ 'state', 'fabric' })
	if not main and errors.code(merr) ~= 'not_found' then
		return nil, merr
	end

	local links, lerr = model:snapshot({ 'state', 'fabric', 'link', '+', '#' })
	if not links then return nil, lerr end

	local out = {}
	for i = 1, #(links.entries or {}) do
		local rec = links.entries[i]
		local topic = rec and rec.topic or nil
		local link_id = type(topic) == 'table' and topic[4] or nil
		local view = type(topic) == 'table' and topic[5] or nil

		if type(link_id) == 'string' and link_id ~= '' and type(view) == 'string' and view ~= '' then
			local slot = out[link_id]
			if not slot then
				slot = {}
				out[link_id] = slot
			end
			slot[view] = rec.payload
		end
	end

	return {
		seq = links.seq,
		main = main and main.payload or nil,
		links = out,
	}, nil
end

function M.fabric_link_status(model, link_id)
	local id, err = require_name(link_id, 'link_id')
	if not id then return nil, err end

	local session, serr = model:get_exact({ 'state', 'fabric', 'link', id, 'session' })
	if not session and errors.code(serr) ~= 'not_found' then return nil, serr end

	local bridge, berr = model:get_exact({ 'state', 'fabric', 'link', id, 'bridge' })
	if not bridge and errors.code(berr) ~= 'not_found' then return nil, berr end

	local transfer, terr = model:get_exact({ 'state', 'fabric', 'link', id, 'transfer' })
	if not transfer and errors.code(terr) ~= 'not_found' then return nil, terr end

	if not session and not bridge and not transfer then
		return nil, errors.not_found('not found')
	end

	return {
		session = session and session.payload or nil,
		bridge = bridge and bridge.payload or nil,
		transfer = transfer and transfer.payload or nil,
	}, nil
end


return M
