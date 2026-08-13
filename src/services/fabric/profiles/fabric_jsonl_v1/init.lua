-- Standard bidirectional fabric-jsonl/1 profile.

local M = {
	kind = 'fabric_jsonl_v1',
	capabilities = {
		session = true,
		publish = true,
		rpc = true,
		transfer = true,
		write = true,
	},
	link_sections = {
		session = true,
		reader = true,
		writer = true,
		bridge = true,
		transfer = true,
		queues = true,
	},
}

function M.compile(args)
	if args == nil then return {}, nil end
	if type(args) ~= 'table' then return nil, 'protocol.args must be a table' end
	if next(args) ~= nil then
		local key = next(args)
		return nil, 'protocol.args has unknown field for fabric_jsonl_v1: ' .. tostring(key)
	end
	return {}, nil
end

function M.run(scope, params, service_caps)
	return require('services.fabric.link').run_composed(scope, params, service_caps)
end

return M
