-- services/net/config.lua
-- Strict cfg/net normalisation boundary for NET.
--
-- This module intentionally accepts only devicecode.config/net/1.  It does not
-- migrate older top-level net/network shapes.  The output is product-level
-- intent, not an OpenWrt or HAL backend plan.

local schema = require 'services.net.schema'

local segments_dom = require 'services.net.domain.segments'
local interfaces_dom = require 'services.net.domain.interfaces'
local addressing_dom = require 'services.net.domain.addressing'
local firewall_dom = require 'services.net.domain.firewall'
local routing_dom = require 'services.net.domain.routing'
local multiwan_dom = require 'services.net.domain.multiwan'
local shaping_dom = require 'services.net.domain.shaping'
local vpn_dom = require 'services.net.domain.vpn'
local dns_dom = require 'services.net.domain.dns'
local dhcp_dom = require 'services.net.domain.dhcp'
local diagnostics_dom = require 'services.net.domain.diagnostics'

local M = {}

local SCHEMA = schema.CONFIG_SCHEMA
local INTENT_SCHEMA = schema.INTENT_SCHEMA

local TOP_LEVEL = {
	'schema', 'version', 'product', 'description',
	'segments', 'interfaces',
	'addressing', 'dns', 'dhcp',
	'firewall', 'routing', 'wan', 'shaping', 'vpn', 'diagnostics',
	'runtime', 'policies', 'metadata', 'extensions',
}

local function payload_record(value)
	if schema.is_plain_table(value) and value.data ~= nil then
		return value.data, value.rev
	end
	return value, nil
end

function M.extract_payload(value)
	return payload_record(value)
end

local RUNTIME_FIELDS = { 'apply', 'observe', 'diagnostics', 'backpressure', 'metadata', 'extensions' }

local function normalise_runtime(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'runtime' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, RUNTIME_FIELDS, { 'net', 'runtime' })
	if not ok then return nil, ferr end
	local out = {
		apply = schema.copy(t.apply or {}),
		observe = schema.copy(t.observe or {}),
		diagnostics = schema.copy(t.diagnostics or {}),
		backpressure = schema.copy(t.backpressure or {}),
	}
	local metadata, merr = schema.copy_optional_table(t.metadata, { 'net', 'runtime', 'metadata' })
	if merr then return nil, merr end
	local extensions, eerr = schema.copy_optional_table(t.extensions, { 'net', 'runtime', 'extensions' })
	if eerr then return nil, eerr end
	out.metadata = metadata
	out.extensions = extensions
	return out, nil
end

local function ensure_shape(intent)
	intent.stats = {
		segments = schema.count_map(intent.segments),
		interfaces = schema.count_map(intent.interfaces),
		wan_members = schema.count_map(intent.wan and intent.wan.members),
		vpn_tunnels = schema.count_map(intent.vpn and intent.vpn.tunnels),
		shaping_profiles = schema.count_map(intent.shaping and intent.shaping.profiles),
	}
	return intent
end

function M.normalise(value, opts)
	opts = opts or {}
	local raw, payload_rev = payload_record(value)
	local t, err = schema.require_plain_table(raw, { 'cfg', 'net' })
	if not t then return nil, err end

	if t.schema ~= SCHEMA then
		return nil, ('cfg/net schema must be %s'):format(SCHEMA)
	end
	local ok, ferr = schema.check_allowed_fields(t, TOP_LEVEL, { 'cfg', 'net' })
	if not ok then return nil, ferr end

	local rev = opts.rev or payload_rev or 0
	if type(rev) == 'number' then rev = math.floor(rev) end
	local version = t.version or schema.DEFAULT_VERSION
	if type(version) ~= 'number' or version % 1 ~= 0 or version < 1 then
		return nil, 'cfg/net.version must be a positive integer when supplied'
	end

	local segments, serr = segments_dom.normalise(t.segments)
	if not segments then return nil, serr end
	local interfaces, ierr = interfaces_dom.normalise(t.interfaces)
	if not interfaces then return nil, ierr end
	local addressing, aerr = addressing_dom.normalise(t.addressing)
	if not addressing then return nil, aerr end
	local dns, dnserr = dns_dom.normalise(t.dns)
	if not dns then return nil, dnserr end
	local dhcp, dhcperr = dhcp_dom.normalise(t.dhcp)
	if not dhcp then return nil, dhcperr end
	local firewall, fwerr = firewall_dom.normalise(t.firewall)
	if not firewall then return nil, fwerr end
	local routing, rerr = routing_dom.normalise(t.routing)
	if not routing then return nil, rerr end
	local wan, werr = multiwan_dom.normalise(t.wan)
	if not wan then return nil, werr end
	local shaping, sherr = shaping_dom.normalise(t.shaping)
	if not shaping then return nil, sherr end
	local vpn, vperr = vpn_dom.normalise(t.vpn)
	if not vpn then return nil, vperr end
	local diagnostics, derr = diagnostics_dom.normalise(t.diagnostics)
	if not diagnostics then return nil, derr end
	local runtime, rterr = normalise_runtime(t.runtime)
	if not runtime then return nil, rterr end
	local policies, perr = schema.copy_table_or_empty(t.policies, { 'net', 'policies' })
	if not policies then return nil, perr end
	local metadata, merr = schema.copy_optional_table(t.metadata, { 'net', 'metadata' })
	if merr then return nil, merr end
	local extensions, eerr = schema.copy_optional_table(t.extensions, { 'net', 'extensions' })
	if eerr then return nil, eerr end

	return ensure_shape({
		schema = INTENT_SCHEMA,
		config_schema = SCHEMA,
		version = version,
		rev = rev,
		generation = opts.generation or 0,
		product = t.product,
		description = t.description,
		segments = segments,
		interfaces = interfaces,
		addressing = addressing,
		dns = dns,
		dhcp = dhcp,
		firewall = firewall,
		routing = routing,
		wan = wan,
		shaping = shaping,
		vpn = vpn,
		diagnostics = diagnostics,
		runtime = runtime,
		policies = policies,
		metadata = metadata,
		extensions = extensions,
	}), nil
end

M.SCHEMA = SCHEMA
M.INTENT_SCHEMA = INTENT_SCHEMA

return M
