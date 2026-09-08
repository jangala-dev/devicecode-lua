-- Decode each legacy JSON line into complete canonical retained facts.
local cjson = require 'cjson.safe'
local tablex = require 'shared.table'
local model = require 'services.fabric.profiles.legacy_mcu_metrics_v1.state_model'

local M = {}

function M.new_processor(protocol)
	return {
		protocol = protocol or {}, model = model.new(), cache = {},
		lines = 0, decoded = 0, decode_errors = 0, published = 0, unchanged = 0,
	}
end

function M.process_line(processor, line, emit)
	if type(processor) ~= 'table' then return nil, 'processor must be a table' end
	if type(emit) ~= 'function' then return nil, 'emit must be a function' end
	processor.lines = processor.lines + 1
	local decoded, err = cjson.decode(line)
	if type(decoded) ~= 'table' or not line:match('^%s*{') then
		processor.decode_errors = processor.decode_errors + 1
		return nil, err or 'legacy MCU JSON line must decode to an object'
	end
	local next_model, touched = model.update(processor.model, decoded, processor.protocol.unsigned_underflow_compat)
	if not next_model then
		processor.decode_errors = processor.decode_errors + 1
		return nil, touched
	end
	processor.decoded = processor.decoded + 1
	local facts = model.project(next_model)
	for _, fact in ipairs(tablex.sorted_keys(touched)) do
		local payload = facts[fact]
		if processor.protocol.change_only ~= true or not tablex.deep_equal(payload, processor.cache[fact]) then
			local ok, emit_err = emit(fact, tablex.deep_copy(payload))
			if ok ~= true then return nil, emit_err or 'legacy MCU fact publish failed' end
			processor.published = processor.published + 1
		else
			processor.unchanged = processor.unchanged + 1
		end
	end
	processor.model, processor.cache = next_model, facts
	return true
end

return M
