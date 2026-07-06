-- services/ui/topics.lua
--
-- Pure topic helpers for the UI service.

local M = {}

local function t(...)
	return { ... }
end

function M.svc_status()
	return t('svc', 'ui', 'status')
end

function M.svc_meta()
	return t('svc', 'ui', 'meta')
end


function M.default_retained_patterns(opts)
	opts = opts or {}
	local patterns = {
		t('state', '#'),
		t('svc', '+', 'status'),
	}
	if opts.include_raw == true then patterns[#patterns + 1] = t('raw', '#') end
	return patterns
end


function M.default_excluded_retained_patterns()
	return {
		t('state', 'ui', '#'),
		t('svc', 'ui', '#'),
		t('obs', 'v1', 'ui', '#'),
	}
end

function M.topic_key(topic)
	assert(type(topic) == 'table', 'topic_key: topic must be a table')
	local out = {}
	for i = 1, #topic do
		local v = topic[i]
		local tv = type(v)
		if tv == 'string' then
			out[#out + 1] = 's' .. #v .. ':' .. v
		elseif tv == 'number' then
			local s = tostring(v)
			out[#out + 1] = 'n' .. #s .. ':' .. s
		else
			error('topic_key: topic tokens must be strings or numbers', 2)
		end
	end
	return table.concat(out, '|')
end

function M.topic_string(topic)
	if type(topic) ~= 'table' then return tostring(topic) end
	local out = {}
	for i = 1, #topic do out[i] = tostring(topic[i]) end
	return table.concat(out, '/')
end

return M
