-- services/net/model.lua
-- Observable NET service model.

local support_model = require 'devicecode.support.model'
local tablex = require 'shared.table'

local M = {}

local function copy(v) return tablex.deep_copy(v) end

function M.initial(service_id)
	return {
		service = 'net',
		service_id = service_id,
		state = 'starting',
		ready = false,
		reason = nil,

		generation = 0,
		config = {
			rev = nil,
			schema = nil,
			config_schema = nil,
			version = nil,
		},

		apply = {
			state = 'idle',
			generation = nil,
			apply_id = nil,
			last_applied_rev = nil,
			last_error = nil,
			last_result = nil,
		},

		intent = {
			active = nil,
			last_rejected = nil,
			generation = nil,
		},

		hal = {
			network_config = 'not_configured',
			network_state = 'not_configured',
			network_diagnostics = 'not_configured',
			last_status = {},
		},

		observed = {
			last_event = nil,
			last_event_at = nil,
			last_subject = nil,
			snapshot = nil,
			interfaces = {},
			segments = {},
		},

		drift = {
			converged = nil,
			items = {},
			updated_at = nil,
		},

		segments = {},
		vlan_policy = {},
		policies = {},
		interfaces = {},
		addressing = {},
		dns = {},
		dhcp = {},
		firewall = {},
		routing = {},
		wan = {},
		wan_runtime = { uplinks = {}, speedtests = {}, live_weights = {}, last_weight_apply = nil },
		shaping = {},
		vpn = {},
		diagnostics = {},

		stats = {
			config_updates = 0,
			apply_started = 0,
			apply_completed = 0,
			stale_completions = 0,
			observations = 0,
			speedtests_started = 0,
			speedtests_completed = 0,
			live_weight_applies = 0,
		},
	}
end

function M.new(service_id, opts)
	opts = opts or {}
	return support_model.new(M.initial(service_id), {
		label = opts.label or 'net.model',
		copy = copy,
	})
end

function M.deep_copy(v) return copy(v) end

return M
