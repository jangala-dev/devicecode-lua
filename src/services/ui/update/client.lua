-- services/ui/update/client.lua
--
-- Update service client boundary. Reusable upstream waits are exposed as Ops.

local M = {}

local function call_opts(opts, default_timeout)
	opts = opts or {}
	return { timeout = (opts.timeout ~= nil) and opts.timeout or (default_timeout or 10.0) }
end

local function update_manager_rpc(method)
	return { 'cap', 'update-manager', 'main', 'rpc', method }
end

function M.create_job_op(conn, artifact_id, opts)
	opts = opts or {}
	local method = opts.create_method or update_manager_rpc('create-job')
	local metadata = opts.metadata or opts.meta
	return conn:call_op(method, {
		artifact_id = artifact_id,
		artifact_ref = artifact_id,
		component = opts.component or opts.target_component or opts.update_component,
		options = opts.options,
		metadata = metadata,
		expected_image_id = opts.expected_image_id
			or (type(metadata) == 'table' and metadata.image_id or nil),
		job_id = opts.job_id,
	}, call_opts(opts, 10.0)):wrap(function (reply, err)
		if reply == nil or err ~= nil then return nil, err end
		if type(reply) == 'table' and reply.job ~= nil then return reply.job end
		return reply
	end)
end

function M.start_job_op(conn, job_id, opts)
	opts = opts or {}
	local method = opts.start_method or update_manager_rpc('start-job')
	return conn:call_op(method, { job_id = job_id }, call_opts(opts, 10.0))
end

return M
