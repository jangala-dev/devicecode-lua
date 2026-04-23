-- services/device/provider_contract.lua
--
-- Small contract helpers for device observation providers.
-- Providers produce logical observation events; the service shell owns state
-- mutation and public publication.

local M = {}

M.tags = {
	fact_changed = 'fact_changed',
	event_seen = 'event_seen',
	source_down = 'source_down',
}

local function non_empty_string(v)
	return type(v) == 'string' and v ~= ''
end

function M.assert_provider(provider, name)
	if type(provider) ~= 'table' or type(provider.run) ~= 'function' then
		return nil, 'provider_missing_run:' .. tostring(name)
	end
	return true, nil
end

function M.normalise_event(ev)
	if type(ev) ~= 'table' then
		return nil, 'provider_event_not_table'
	end
	if not non_empty_string(ev.tag) then
		return nil, 'provider_event_missing_tag'
	end
	if ev.tag == M.tags.fact_changed then
		if not non_empty_string(ev.fact) then return nil, 'fact_changed_missing_fact' end
	elseif ev.tag == M.tags.event_seen then
		if not non_empty_string(ev.event) then return nil, 'event_seen_missing_event' end
	elseif ev.tag == M.tags.source_down then
		-- reason is optional
	else
		return nil, 'unknown_provider_event:' .. tostring(ev.tag)
	end
	return ev, nil
end

function M.emit(emit_fn, ev)
	local normalised, err = M.normalise_event(ev)
	if not normalised then error(err, 2) end
	return emit_fn(normalised)
end

return M
