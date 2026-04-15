-- services/net/model.lua
--
-- NET runtime model and dirty-marker helpers.

local runtime = require 'fibers.runtime'

local M = {}

local function now()
	return runtime.now()
end

local function inf()
	return 1 / 0
end

M.inf = inf

function M.new_runtime_link(old, spec)
	local link = old or {
		facts = {},
		probe = {},
		health = {},
		counters = {},
		autorate = {},
		multipath = {},
	}

	link.spec = spec

	link.probe.next_at         = link.probe.next_at or 0
	link.probe.round           = link.probe.round or 0
	link.probe.last_sent_at    = link.probe.last_sent_at
	link.probe.last_reply_at   = link.probe.last_reply_at

	link.health.state              = link.health.state or 'unknown'
	link.health.reason             = link.health.reason or 'no_samples'
	link.health.baseline_rtt_ms    = link.health.baseline_rtt_ms
	link.health.recent_rtt_ms      = link.health.recent_rtt_ms
	link.health.delay_rtt_ms       = link.health.delay_rtt_ms
	link.health.loss_pct_ewma      = link.health.loss_pct_ewma
	link.health.success_streak     = link.health.success_streak or 0
	link.health.failure_streak     = link.health.failure_streak or 0
	link.health.last_transition_at = link.health.last_transition_at

	link.counters.last_at       = link.counters.last_at
	link.counters.last_rx_bytes = link.counters.last_rx_bytes
	link.counters.last_tx_bytes = link.counters.last_tx_bytes
	link.counters.rx_bps        = link.counters.rx_bps or 0
	link.counters.tx_bps        = link.counters.tx_bps or 0

	link.autorate.current_up_kbit   = link.autorate.current_up_kbit
	link.autorate.current_down_kbit = link.autorate.current_down_kbit
	link.autorate.last_apply_at     = link.autorate.last_apply_at
	link.autorate.reason            = link.autorate.reason or 'initial'

	local mp = spec.multipath or {}
	link.multipath.live_weight   = link.multipath.live_weight or (mp.base_weight or 1)
	link.multipath.live_member   = link.multipath.live_member ~= false
	link.multipath.last_apply_at = link.multipath.last_apply_at

	return link
end

function M.build_runtime_model(bundle)
	local model = {
		bundle = bundle,

		structural = {
			dirty         = true,
			next_apply_at = now(),
			retry_s       = 1.0,
			retry_max_s   = 30.0,
		},

		inventory = {
			dirty       = true,
			next_at     = now(),
			retry_s     = 2.0,
			retry_max_s = 30.0,
		},

		probing = {
			dirty       = true,
			next_at     = now(),
			retry_s     = 1.0,
			retry_max_s = 10.0,
		},

		counters = {
			dirty       = true,
			next_at     = now(),
			retry_s     = 1.0,
			retry_max_s = 10.0,
		},

		control = {
			dirty   = true,
			next_at = now(),
		},

		persist = {
			dirty    = false,
			next_at  = inf(),
			last_sig = nil,
		},

		last_shaper_sig    = nil,
		last_multipath_sig = nil,
		links = {},
	}

	for link_id, spec in pairs(bundle.runtime.links or {}) do
		model.links[link_id] = M.new_runtime_link(nil, spec)
	end

	return model
end

function M.merge_bundle_into_model(model, bundle)
	local new_links = {}

	for link_id, spec in pairs(bundle.runtime.links or {}) do
		new_links[link_id] = M.new_runtime_link(model.links[link_id], spec)
	end

	model.bundle = bundle
	model.links  = new_links

	model.structural.dirty         = true
	model.inventory.dirty          = true
	model.probing.dirty            = true
	model.counters.dirty           = true
	model.control.dirty            = true

	model.structural.next_apply_at = now() + (bundle.runtime.timings.structural_debounce_s or 0.25)
	model.inventory.next_at        = now()
	model.probing.next_at          = now()
	model.counters.next_at         = now()
	model.control.next_at          = now()
end

function M.mark_control_dirty(model, when_s)
	model.control.dirty = true
	model.control.next_at = math.min(model.control.next_at or inf(), when_s or now())
end

function M.mark_inventory_dirty(model, when_s)
	model.inventory.dirty = true
	model.inventory.next_at = math.min(model.inventory.next_at or inf(), when_s or now())
end

function M.mark_probe_dirty(model, when_s)
	model.probing.dirty = true
	model.probing.next_at = math.min(model.probing.next_at or inf(), when_s or now())
end

function M.mark_counter_dirty(model, when_s)
	model.counters.dirty = true
	model.counters.next_at = math.min(model.counters.next_at or inf(), when_s or now())
end

function M.mark_persist_dirty(model, when_s)
	model.persist.dirty = true
	model.persist.next_at = math.min(model.persist.next_at or inf(), when_s or now())
end

return M
