-- services/fabric.lua
--
-- Public Fabric assembly entry point.
--
-- This module deliberately stays thin. The semantic owners live under
-- services.fabric.*; this file wires the default service runner to the standard
-- composed link runner.

local fibers   = require 'fibers'
local service  = require 'services.fabric.service'
local link     = require 'services.fabric.link'
local io       = require 'services.fabric.io'
local bridge   = require 'services.fabric.bridge'
local bus_adapter = require 'services.fabric.bus_adapter'
local session  = require 'services.fabric.session'
local transfer = require 'services.fabric.transfer'
local transfer_client = require 'services.fabric.transfer_client'
local transfer_sender = require 'services.fabric.transfer_sender'
local transfer_receive = require 'services.fabric.transfer_receive'
local hal_transport = require 'services.fabric.hal_transport'
local model    = require 'services.fabric.model'
local protocol = require 'services.fabric.protocol'
local topics   = require 'services.fabric.topics'
local config   = require 'services.fabric.config'
local state    = require 'services.fabric.state'
local dep_failure = require 'devicecode.support.dependency_failure'
local tablex   = require 'shared.table'

local M = {
	service  = service,
	link     = link,
	io       = io,
	bridge   = bridge,
	bus_adapter = bus_adapter,
	session  = session,
	transfer = transfer,
	transfer_client = transfer_client,
	transfer_sender = transfer_sender,
	transfer_receive = transfer_receive,
	model    = model,
	protocol = protocol,
	topics   = topics,
	config   = config,
	state    = state,
}

local shallow_copy = tablex.shallow_copy

local function has_terminate_contract(x)
	return type(x) == 'table' and type(x.terminate) == 'function'
end

local function is_frame_transport(x)
	return type(x) == 'table'
		and type(x.read_frame_op) == 'function'
		and type(x.write_frame_op) == 'function'
		and has_terminate_contract(x)
end

local function link_conn(link_spec, service_caps)
	return link_spec.conn or (service_caps and service_caps.conn)
end

local function link_dependency_key(link_spec)
	if type(link_spec) ~= 'table' then return nil end
	if type(link_spec.dependency_key) == 'string' and link_spec.dependency_key ~= '' then
		return link_spec.dependency_key
	end
	local t = link_spec.transport
	if type(t) == 'table' and type(t.dependency_key) == 'string' and t.dependency_key ~= '' then
		return t.dependency_key
	end
	return nil
end

local function normalise_transport_open_error(link_spec, out)
	local dep_key = out.dependency_key or link_dependency_key(link_spec)
	if out.link_id == nil and type(link_spec) == 'table' then out.link_id = link_spec.link_id end
	if dep_key ~= nil then out.dependency_key = dep_key end
	local failure = dep_failure.from_no_route(dep_key, out, {
		link_id = out.link_id,
		source = out.source,
		class = out.class,
		id = out.id,
	})
	if failure ~= nil then return failure end
	return out
end
local function transport_open_error(link_spec, err, fallback)
	local out
	if type(err) == 'table' then
		out = normalise_transport_open_error(link_spec, shallow_copy(err))
	else
		out = normalise_transport_open_error(link_spec, {
			err = err or fallback or 'transport_open_failed',
			detail = err,
			reason = err or fallback or 'transport_open_failed',
		})
	end
	if type(out) == 'table' and out.kind == 'dependency_failure' then
		return out
	end
	if type(err) == 'table' then
		return out
	end
	return out.err or out.reason or fallback or 'transport_open_failed'
end

local function open_transport_for_link(scope, link_spec, service_caps)
	if is_frame_transport(link_spec.transport) then
		return link_spec.transport, nil
	end

	if type(link_spec.open_transport_op) == 'function' then
		local transport, err = fibers.perform(link_spec.open_transport_op(scope, service_caps))
		if transport == nil then
			return nil, transport_open_error(link_spec, err, 'transport_open_failed')
		end
		if not is_frame_transport(transport) then
			return nil, transport_open_error(link_spec, 'transport_open_returned_non_frame_transport')
		end
		return transport, nil
	end

	if link_spec.transport ~= nil then
		local transport_cfg = link_spec.transport
		if type(transport_cfg) == 'table' and link_spec.trace_io ~= nil then
			transport_cfg = shallow_copy(transport_cfg)
			transport_cfg.trace_io = link_spec.trace_io == true
		end
		local transport, err = hal_transport.open_transport(
			link_conn(link_spec, service_caps),
			transport_cfg
		)
		if transport == nil then
			return nil, transport_open_error(link_spec, err, 'transport_open_failed')
		end
		return transport, nil
	end

	return nil, transport_open_error(link_spec, 'fabric link transport required')
end

--- Default link runner used by the public Fabric service entry point.
function M.run_link(scope, link_spec, service_caps)
	if type(scope) ~= 'table' then
		error('fabric.run_link: scope required', 2)
	end
	if type(link_spec) ~= 'table' then
		error('fabric.run_link: link_spec table required', 2)
	end

	local p = shallow_copy(link_spec)
	local transport, err = open_transport_for_link(scope, p, service_caps)
	if transport == nil then
		error(err or 'fabric link transport open failed', 0)
	end

	p.transport = transport
	p.open_transport_op = nil

	return link.run_composed(scope, p, service_caps)
end

--- Start the long-lived public Fabric service shell.
---
--- opts is the same shape accepted by services.fabric.service.start, except that
--- link_runner defaults to services.fabric.link.run_composed.
function M.start(conn, opts)
	opts = opts or {}
	local p = shallow_copy(opts)
	p.link_runner = p.link_runner or M.run_link
	if p.link_runner == M.run_link then
		p._private_link_runtime = true
	end
	return service.start(conn, p)
end

--- Run one Fabric generation using the standard composed-link implementation.
---
--- params is the same shape accepted by services.fabric.service.run, except that
--- link_runner defaults to services.fabric.link.run_composed.
function M.run(scope, params)
	if type(scope) ~= 'table' then
		error('fabric.run: scope required', 2)
	end
	if type(params) ~= 'table' then
		error('fabric.run: params table required', 2)
	end

	local p = shallow_copy(params)
	p.link_runner = p.link_runner or M.run_link
	if p.link_runner == M.run_link then
		p._private_link_runtime = true
	end

	return service.run(scope, p)
end

return M
