-- Pure decoder and change filter for the original Big Box MCU JSONL output.

local cjson = require 'cjson.safe'

local M = {}

local UINT32 = 4294967296
local UNDERFLOW_THRESHOLD = 1000000

local function trim(s)
	return tostring(s):gsub('^%s*(.-)%s*$', '%1')
end

local function metric_route(protocol, key)
	local namespace = {}
	for i = 1, #(protocol.namespace_prefix or {}) do
		namespace[#namespace + 1] = protocol.namespace_prefix[i]
	end
	local metric_name
	for segment in tostring(key):gmatch('[^/]+') do
		namespace[#namespace + 1] = segment
		metric_name = segment
	end
	if metric_name == nil then return nil, nil end
	return metric_name, namespace
end

local function compatible_value(protocol, value)
	if protocol.unsigned_underflow_compat == true
		and type(value) == 'number'
		and value > UNDERFLOW_THRESHOLD
	then
		return value - UINT32
	end
	return value
end

function M.new_processor(protocol)
	return {
		protocol = protocol or {},
		cache = {},
		lines = 0,
		decoded = 0,
		decode_errors = 0,
		published = 0,
		unchanged = 0,
	}
end

function M.process_line(processor, line, emit)
	if type(processor) ~= 'table' then return nil, 'processor must be a table' end
	if type(emit) ~= 'function' then return nil, 'emit must be a function' end
	processor.lines = (processor.lines or 0) + 1

	local json_string = trim(line)
	local decoded, err = cjson.decode(json_string)
	if decoded == nil then
		processor.decode_errors = (processor.decode_errors or 0) + 1
		return nil, tostring(err or 'invalid JSON')
	end
	if type(decoded) ~= 'table' then
		processor.decode_errors = (processor.decode_errors or 0) + 1
		return nil, 'legacy MCU JSON line must decode to an object'
	end
	processor.decoded = (processor.decoded or 0) + 1

	for key, raw_value in pairs(decoded) do
		if type(key) == 'string' then
			local value = compatible_value(processor.protocol, raw_value)
			local changed = processor.protocol.change_only ~= true or processor.cache[key] ~= value
			if changed then
				local metric_name, namespace = metric_route(processor.protocol, key)
				if metric_name ~= nil then
					local ok, emit_err = emit(metric_name, value, namespace)
					if ok ~= true then return nil, emit_err or 'legacy MCU metric publish failed' end
					processor.cache[key] = value
					processor.published = (processor.published or 0) + 1
				end
			else
				processor.unchanged = (processor.unchanged or 0) + 1
			end
		end
	end
	return true, nil
end

return M
