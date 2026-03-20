-- services/net.lua
--
-- Net service.
--
-- This version keeps the existing "structural apply" path:
--   config/net (retained) -> compiler -> rpc/hal/apply_net
--
-- and adds explicit stubs for the "runtime control" path:
--   * link inventory refresh
--   * shared probe scheduling
--   * link health classification
--   * counter sampling / load estimation
--   * per-link autorate decisions
--   * live multiwan membership / weight decisions
--   * live dataplane apply without full reload
--   * delayed persistence of live decisions back into OS config
--
-- The intent is:
--   * HAL remains the only place that touches the OS
--   * NET owns all judgement, smoothing, thresholds and policy
--
-- The HAL RPC names used below are provisional and should be treated as
-- the contract that HAL will eventually implement:
--
--   * apply_net                structural apply; you already have this
--   * list_links               return current logical uplinks / resolved devices / facts
--   * probe_links              execute one probe round for a set of logical links
--   * read_link_counters       read byte / packet counters for a set of links
--   * apply_link_shaping_live  apply live shaper changes without structural reload
--   * apply_multipath_live     apply live member/weight changes without structural reload
--   * persist_multipath_state  write the latest live weights/members to OS config
--
-- None of those runtime RPCs need to exist yet; this file is laying out where
-- and how NET will consume them.

local fibers   = require 'fibers'
local runtime  = require 'fibers.runtime'
local sleep    = require 'fibers.sleep'
local op       = require 'fibers.op'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local base      = require 'devicecode.service_base'
local compiler  = require 'services.net.compiler'

local M = {}

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function now()
	return runtime.now()
end

local function inf()
	return 1 / 0
end

local function is_plain_table(x)
	return type(x) == 'table' and getmetatable(x) == nil
end

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function min_deadline(...)
	local best = inf()
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if type(v) == 'number' and v < best then best = v end
	end
	return best
end

local function clamp_num(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function stable_sig(v)
	-- Small stable serialiser used only to detect semantic changes in control
	-- requests. This avoids needless HAL calls when the derived live request is
	-- materially unchanged from the last one.
	if v == nil then return 'nil' end

	local tv = type(v)
	if tv == 'boolean' or tv == 'number' or tv == 'string' then
		return tv .. ':' .. tostring(v)
	end

	if tv ~= 'table' then
		return tv .. ':' .. tostring(v)
	end

	local parts = {}
	local ks = sorted_keys(v)
	parts[#parts + 1] = '{'
	for i = 1, #ks do
		local k = ks[i]
		parts[#parts + 1] = stable_sig(k)
		parts[#parts + 1] = '='
		parts[#parts + 1] = stable_sig(v[k])
		parts[#parts + 1] = ';'
	end
	parts[#parts + 1] = '}'
	return table.concat(parts)
end

--------------------------------------------------------------------------------
-- Compile helpers
--------------------------------------------------------------------------------

local function compile_bundle_from_config(cfg, rev, gen)
	-- NET needs two different products from compilation:
	--
	--   1. desired  -> structural desired state for HAL apply_net
	--   2. runtime  -> NET-local policy model for monitoring / autorate /
	--                  live multiwan control
	--
	-- The compiler extension below provides compile_bundle() specifically so that
	-- these two products stay derived from the same config revision.
	return compiler.compile_bundle(cfg, {
		rev = rev,
		gen = gen,
	})
end

--------------------------------------------------------------------------------
-- Runtime model construction
--------------------------------------------------------------------------------

local function new_runtime_link(old, spec)
	-- Rebuild one logical link entry while preserving runtime history where we can.
	--
	-- "spec" comes from compiler.runtime.links[link_id].
	-- It is the policy/static description of the logical link:
	--   * metric / base weight / dynamic weight flag
	--   * probe parameters
	--   * shaping policy
	--   * whether this link participates in multiwan
	--
	-- "old" is the previous runtime object, which may already contain:
	--   * EWMA RTT baseline / recent
	--   * failure / success streaks
	--   * last probe result timestamps
	--   * last counter sample and calculated throughputs
	--   * last desired shaper rate
	--   * last derived live weight
	--
	-- We keep all those runtime fields because config revisions should not wipe
	-- operational history unless the logical link itself disappears.
	local link = old or {
		facts = {},      -- resolved HAL facts, e.g. current device, source addr, gateway
		probe = {},      -- probe runtime state
		health = {},     -- derived health / RTT / loss view
		counters = {},   -- last raw counters and derived rates
		autorate = {},   -- current desired rate outputs
		multipath = {},  -- current live membership / weight view
	}

	link.spec = spec

	-- Probe scheduling state.
	link.probe.next_at        = link.probe.next_at or 0
	link.probe.round         = link.probe.round or 0
	link.probe.last_sent_at   = link.probe.last_sent_at
	link.probe.last_reply_at  = link.probe.last_reply_at

	-- Health state starts conservative; later passes will update this.
	link.health.state              = link.health.state or 'unknown'  -- unknown|online|degraded|offline
	link.health.reason             = link.health.reason or 'no_samples'
	link.health.baseline_rtt_ms    = link.health.baseline_rtt_ms
	link.health.recent_rtt_ms      = link.health.recent_rtt_ms
	link.health.delay_rtt_ms       = link.health.delay_rtt_ms
	link.health.loss_pct_ewma      = link.health.loss_pct_ewma
	link.health.success_streak     = link.health.success_streak or 0
	link.health.failure_streak     = link.health.failure_streak or 0
	link.health.last_transition_at = link.health.last_transition_at

	-- Counter state; HAL returns raw counters and NET derives rate deltas.
	link.counters.last_at       = link.counters.last_at
	link.counters.last_rx_bytes = link.counters.last_rx_bytes
	link.counters.last_tx_bytes = link.counters.last_tx_bytes
	link.counters.rx_bps        = link.counters.rx_bps or 0
	link.counters.tx_bps        = link.counters.tx_bps or 0

	-- Autorate output state. Even before the real controller exists, we keep
	-- explicit fields so the interface between the control code and HAL is clear.
	link.autorate.current_up_kbit   = link.autorate.current_up_kbit
	link.autorate.current_down_kbit = link.autorate.current_down_kbit
	link.autorate.last_apply_at     = link.autorate.last_apply_at
	link.autorate.reason            = link.autorate.reason or 'initial'

	-- Live multiwan state derived by NET and pushed into HAL.
	link.multipath.live_weight  = link.multipath.live_weight or (spec.base_weight or 1)
	link.multipath.live_member  = link.multipath.live_member ~= false
	link.multipath.last_apply_at = link.multipath.last_apply_at

	return link
end

local function build_runtime_model(bundle)
	-- Construct the full NET runtime model for one compiled config revision.
	--
	-- This object is the service's entire working set. It holds:
	--   * compiled structural desired state
	--   * compiled runtime policy
	--   * per-link operational state
	--   * scheduling deadlines
	--   * retry/backoff state
	--   * last request signatures to suppress duplicate HAL calls
	local model = {
		bundle = bundle,

		-- Structural apply tracking.
		structural = {
			dirty        = true,
			next_apply_at = now(),
			retry_s      = 1.0,
			retry_max_s  = 30.0,
		},

		-- Inventory refresh pulls current OS-level facts from HAL:
		-- resolved devices, addresses, gateway/source info, carrier facts, etc.
		inventory = {
			dirty        = true,
			next_at      = now(),
			retry_s      = 2.0,
			retry_max_s  = 30.0,
		},

		-- Probe rounds ask HAL to actively test links.
		probing = {
			dirty        = true,
			next_at      = now(),
			retry_s      = 1.0,
			retry_max_s  = 10.0,
		},

		-- Counter sampling asks HAL for byte/packet counters.
		counters = {
			dirty        = true,
			next_at      = now(),
			retry_s      = 1.0,
			retry_max_s  = 10.0,
		},

		-- Control pass derives health, shaping and multiwan decisions.
		control = {
			dirty        = true,
			next_at      = now(),
		},

		-- Persistence is intentionally separate from live apply:
		-- live dataplane updates may happen quite often;
		-- persistence back to OS config should be delayed and rate-limited.
		persist = {
			dirty        = false,
			next_at      = inf(),
			last_sig     = nil,
		},

		-- Request signatures let us suppress live apply calls whose semantic
		-- content has not changed.
		last_shaper_sig    = nil,
		last_multipath_sig = nil,

		links = {},
	}

	for link_id, spec in pairs(bundle.runtime.links or {}) do
		model.links[link_id] = new_runtime_link(nil, spec)
	end

	return model
end

local function merge_bundle_into_model(model, bundle)
	-- Merge a newly compiled bundle into the existing runtime model.
	--
	-- We rebuild the static/policy parts from the compiler output, but preserve
	-- the operational runtime state of links that remain present across revisions.
	local new_links = {}

	for link_id, spec in pairs(bundle.runtime.links or {}) do
		new_links[link_id] = new_runtime_link(model.links[link_id], spec)
	end

	model.bundle = bundle
	model.links  = new_links

	-- Any new config revision should trigger all relevant paths:
	--   * structural apply because desired structural state may have changed
	--   * inventory refresh because devices/links may have changed
	--   * control pass because policy may have changed
	-- It should not immediately force a persistence write; persistence is for
	-- runtime decisions that have stabilised.
	model.structural.dirty   = true
	model.inventory.dirty    = true
	model.probing.dirty      = true
	model.counters.dirty     = true
	model.control.dirty      = true

	model.structural.next_apply_at = now() + (bundle.runtime.timings.structural_debounce_s or 0.25)
	model.inventory.next_at        = now()
	model.probing.next_at          = now()
	model.counters.next_at         = now()
	model.control.next_at          = now()
end

--------------------------------------------------------------------------------
-- Dirty markers
--------------------------------------------------------------------------------

local function mark_control_dirty(model, when_s)
	model.control.dirty = true
	model.control.next_at = math.min(model.control.next_at or inf(), when_s or now())
end

local function mark_inventory_dirty(model, when_s)
	model.inventory.dirty = true
	model.inventory.next_at = math.min(model.inventory.next_at or inf(), when_s or now())
end

local function mark_probe_dirty(model, when_s)
	model.probing.dirty = true
	model.probing.next_at = math.min(model.probing.next_at or inf(), when_s or now())
end

local function mark_counter_dirty(model, when_s)
	model.counters.dirty = true
	model.counters.next_at = math.min(model.counters.next_at or inf(), when_s or now())
end

local function mark_persist_dirty(model, when_s)
	model.persist.dirty = true
	model.persist.next_at = math.min(model.persist.next_at or inf(), when_s or now())
end

--------------------------------------------------------------------------------
-- Observability stubs
--------------------------------------------------------------------------------

local function publish_link_state_stub(conn, svc, link_id, link)
	-- This is a stub for retained / event publication of NET's interpreted view.
	--
	-- Recommended future shape:
	--   retain  state/net/link/<id>
	--   publish obs/event/net/link_health
	--
	-- The retained state should be NET's judgement, not raw HAL facts:
	--   * state=online|degraded|offline
	--   * reason
	--   * baseline/recent/delay RTT
	--   * loss
	--   * last desired up/down rates
	--   * last live weight
	--
	-- Keeping that publication in NET is important: HAL should publish facts,
	-- NET should publish interpretation.
	conn:retain({ 'state', 'net', 'link', link_id }, {
		state            = link.health.state,
		reason           = link.health.reason,
		baseline_rtt_ms  = link.health.baseline_rtt_ms,
		recent_rtt_ms    = link.health.recent_rtt_ms,
		delay_rtt_ms     = link.health.delay_rtt_ms,
		loss_pct_ewma    = link.health.loss_pct_ewma,
		tx_bps           = link.counters.tx_bps,
		rx_bps           = link.counters.rx_bps,
		up_kbit          = link.autorate.current_up_kbit,
		down_kbit        = link.autorate.current_down_kbit,
		live_weight      = link.multipath.live_weight,
		at               = svc:wall(),
		ts               = svc:now(),
	})
end

--------------------------------------------------------------------------------
-- HAL inventory refresh
--------------------------------------------------------------------------------

local function refresh_inventory(svc, model)
	-- Ask HAL for the current OS-facing inventory and resolved link facts.
	--
	-- Expected future reply shape:
	--   {
	--     ok = true,
	--     links = {
	--       wan = {
	--         device = "eth0.2",
	--         source_ip = "10.0.3.15",
	--         gateway = "10.0.3.2",
	--         ifindex = 7,
	--         carrier = true,
	--         operstate = "up",
	--       },
	--       ...
	--     }
	--   }
	--
	-- NET does not decide how those facts are gathered; HAL does.
	local reply, err = svc:hal_call('list_links', {}, 5.0)

	if not reply or reply.ok ~= true or type(reply.links) ~= 'table' then
		svc:obs_log('warn', {
			what = 'inventory_refresh_failed',
			err  = tostring((reply and reply.err) or err),
		})
		model.inventory.next_at = now() + model.inventory.retry_s
		model.inventory.retry_s = math.min(model.inventory.retry_s * 2, model.inventory.retry_max_s)
		return
	end

	for link_id, facts in pairs(reply.links) do
		local link = model.links[link_id]
		if link then
			link.facts = facts
		end
	end

	model.inventory.dirty   = false
	model.inventory.next_at = now() + (model.bundle.runtime.timings.inventory_refresh_s or 30.0)
	model.inventory.retry_s = 2.0

	-- Control decisions may change if the resolved device/source changed.
	mark_control_dirty(model, now())
end

--------------------------------------------------------------------------------
-- Probe execution and ingestion
--------------------------------------------------------------------------------

local function due_probe_links(model, tnow)
	local out = {}
	for link_id, link in pairs(model.links) do
		if (link.spec.health or {}).enabled ~= false then
			if (link.probe.next_at or 0) <= tnow then
				out[#out + 1] = link_id
			end
		end
	end
	table.sort(out)
	return out
end

local function ingest_probe_sample_stub(link, sample, tnow)
	-- This is the NET-side measurement ingestion point.
	--
	-- HAL should only return raw-ish sample results, for example:
	--   { ok=true, rtt_ms=42.1, reflector="1.1.1.1" }
	--   { ok=false, timeout=true }
	--
	-- NET then owns:
	--   * EWMA baseline and recent smoothing
	--   * loss smoothing
	--   * success/failure streaks
	--   * later health classification
	--
	-- The placeholder below is intentionally simple, but it shows where the
	-- fuller sqm-autorate-like logic will sit.
	link.probe.last_reply_at = tnow

	if sample and sample.ok == true and type(sample.rtt_ms) == 'number' then
		local rtt = tonumber(sample.rtt_ms)

		link.health.success_streak = (link.health.success_streak or 0) + 1
		link.health.failure_streak = 0

		-- Slow baseline EWMA. If we observe a lower RTT than baseline, we snap the
		-- baseline downwards because "negative queueing delay" is not meaningful.
		if link.health.baseline_rtt_ms == nil then
			link.health.baseline_rtt_ms = rtt
		else
			local alpha_base = ((link.spec.health or {}).baseline_alpha) or 0.05
			local old = link.health.baseline_rtt_ms
			local nextv = old * (1 - alpha_base) + rtt * alpha_base
			if rtt < nextv then nextv = rtt end
			link.health.baseline_rtt_ms = nextv
		end

		-- Faster recent EWMA.
		if link.health.recent_rtt_ms == nil then
			link.health.recent_rtt_ms = rtt
		else
			local alpha_recent = ((link.spec.health or {}).recent_alpha) or 0.50
			local old = link.health.recent_rtt_ms
			link.health.recent_rtt_ms = old * (1 - alpha_recent) + rtt * alpha_recent
		end

		local base = link.health.baseline_rtt_ms or rtt
		local recent = link.health.recent_rtt_ms or rtt
		link.health.delay_rtt_ms = math.max(0, recent - base)

		local old_loss = link.health.loss_pct_ewma
		if old_loss == nil then
			link.health.loss_pct_ewma = 0
		else
			link.health.loss_pct_ewma = old_loss * 0.80
		end
	else
		link.health.failure_streak = (link.health.failure_streak or 0) + 1
		link.health.success_streak = 0

		local old_loss = link.health.loss_pct_ewma or 0
		link.health.loss_pct_ewma = clamp_num(old_loss * 0.80 + 20.0, 0, 100)
	end
end

local function run_probe_round(svc, model)
	local tnow = now()
	local due = due_probe_links(model, tnow)

	if #due == 0 then
		model.probing.dirty = false
		model.probing.next_at = tnow + 0.50
		return
	end

	local req = { links = {} }
	for i = 1, #due do
		local link_id = due[i]
		local link = model.links[link_id]
		local hs = link.spec.health or {}

		req.links[link_id] = {
			method    = hs.method or 'ping',
			reflectors = hs.reflectors or {},
			timeout_s = hs.timeout_s or 2.0,
			count     = hs.count or 1,
		}

		link.probe.round       = (link.probe.round or 0) + 1
		link.probe.last_sent_at = tnow
	end

	local reply, err = svc:hal_call('probe_links', req, 5.0)

	if not reply or reply.ok ~= true or type(reply.samples) ~= 'table' then
		svc:obs_log('warn', {
			what = 'probe_round_failed',
			err  = tostring((reply and reply.err) or err),
		})
		model.probing.next_at = tnow + model.probing.retry_s
		model.probing.retry_s = math.min(model.probing.retry_s * 2, model.probing.retry_max_s)
		return
	end

	for link_id, sample in pairs(reply.samples) do
		local link = model.links[link_id]
		if link then
			ingest_probe_sample_stub(link, sample, tnow)
			local interval_s = ((link.spec.health or {}).interval_s) or (model.bundle.runtime.timings.probe_interval_s or 2.0)
			link.probe.next_at = tnow + interval_s
		end
	end

	model.probing.dirty   = false
	model.probing.next_at = tnow + 0.50
	model.probing.retry_s = 1.0

	mark_control_dirty(model, now())
end

--------------------------------------------------------------------------------
-- Counter sampling and throughput estimation
--------------------------------------------------------------------------------

local function run_counter_sample(svc, model)
	-- Ask HAL for raw counters and derive rates inside NET.
	--
	-- HAL should return counters by logical link id, for example:
	--   {
	--     ok = true,
	--     links = {
	--       wan = { rx_bytes=..., tx_bytes=..., rx_packets=..., tx_packets=... },
	--       ...
	--     }
	--   }
	local req = { links = sorted_keys(model.links) }
	local reply, err = svc:hal_call('read_link_counters', req, 5.0)

	if not reply or reply.ok ~= true or type(reply.links) ~= 'table' then
		svc:obs_log('warn', {
			what = 'counter_sample_failed',
			err  = tostring((reply and reply.err) or err),
		})
		model.counters.next_at = now() + model.counters.retry_s
		model.counters.retry_s = math.min(model.counters.retry_s * 2, model.counters.retry_max_s)
		return
	end

	local tnow = now()

	for link_id, raw in pairs(reply.links) do
		local link = model.links[link_id]
		if link and type(raw.rx_bytes) == 'number' and type(raw.tx_bytes) == 'number' then
			local c = link.counters

			if c.last_at ~= nil and c.last_rx_bytes ~= nil and c.last_tx_bytes ~= nil then
				local dt = tnow - c.last_at
				if dt > 0 then
					local drx = raw.rx_bytes - c.last_rx_bytes
					local dtx = raw.tx_bytes - c.last_tx_bytes

					if drx >= 0 then c.rx_bps = (drx * 8) / dt end
					if dtx >= 0 then c.tx_bps = (dtx * 8) / dt end
				end
			end

			c.last_at       = tnow
			c.last_rx_bytes = raw.rx_bytes
			c.last_tx_bytes = raw.tx_bytes
		end
	end

	model.counters.dirty   = false
	model.counters.next_at = tnow + (model.bundle.runtime.timings.counter_interval_s or 1.0)
	model.counters.retry_s = 1.0

	mark_control_dirty(model, now())
end

--------------------------------------------------------------------------------
-- Health classification
--------------------------------------------------------------------------------

local function classify_link_health_stub(link, tnow)
	-- This is the NET-owned health judgement.
	--
	-- The real version should eventually include:
	--   * explicit online / degraded / offline hysteresis
	--   * hold-down timers
	--   * multiple reflectors / reliability thresholds
	--   * separate "carrier lost" vs "probe lost" reasons when HAL provides them
	--
	-- For now the logic is intentionally simple and conservative:
	--   * sustained failures -> offline
	--   * excessive RTT inflation or loss -> degraded
	--   * otherwise online
	local hs = link.spec.health or {}

	local failure_down   = tonumber(hs.down or 2) or 2
	local delay_bad_ms   = tonumber(hs.failure_delay_ms or hs.failure_latency_ms or 150) or 150
	local loss_bad_pct   = tonumber(hs.failure_loss_pct or hs.failure_loss or 40) or 40
	local stale_after_s  = tonumber(hs.stale_after_s or (hs.interval_s or 2.0) * 3) or 6.0

	local new_state
	local reason

	if link.probe.last_reply_at == nil or (tnow - link.probe.last_reply_at) > stale_after_s then
		new_state = 'offline'
		reason = 'stale_probes'
	elseif (link.health.failure_streak or 0) >= failure_down then
		new_state = 'offline'
		reason = 'probe_failures'
	elseif (link.health.delay_rtt_ms or 0) >= delay_bad_ms then
		new_state = 'degraded'
		reason = 'high_delay'
	elseif (link.health.loss_pct_ewma or 0) >= loss_bad_pct then
		new_state = 'degraded'
		reason = 'high_loss'
	else
		new_state = 'online'
		reason = 'healthy'
	end

	if link.health.state ~= new_state then
		link.health.last_transition_at = tnow
	end

	link.health.state  = new_state
	link.health.reason = reason
end

--------------------------------------------------------------------------------
-- Autorate control
--------------------------------------------------------------------------------

local function compute_autorate_stub(link, tnow)
	-- This is a placeholder controller for per-link shaping rates.
	--
	-- The real controller will likely become its own helper/module and should
	-- eventually use:
	--   * baseline RTT and recent RTT
	--   * load relative to current applied rate
	--   * min/max bounds
	--   * step-up / step-down curves
	--   * minimum change interval
	--   * separate uplink/downlink control
	--
	-- For now this stub does three things:
	--   1. initialises rates from configured static/base values
	--   2. when the link is degraded, nudges rates down
	--   3. when the link is healthy and utilisation is high, nudges rates up
	local sh = link.spec.shaping or {}
	if sh.enabled ~= true then
		return
	end

	local ar = sh.autorate or {}
	local min_up   = tonumber(ar.min_up_kbit or sh.static_up_kbit or 1000) or 1000
	local max_up   = tonumber(ar.max_up_kbit or sh.static_up_kbit or min_up) or min_up
	local min_down = tonumber(ar.min_down_kbit or sh.static_down_kbit or 1000) or 1000
	local max_down = tonumber(ar.max_down_kbit or sh.static_down_kbit or min_down) or min_down

	-- First assignment uses configured maxima/static values as a sane starting point.
	if link.autorate.current_up_kbit == nil then
		link.autorate.current_up_kbit = max_up
	end
	if link.autorate.current_down_kbit == nil then
		link.autorate.current_down_kbit = max_down
	end

	local min_change_interval_s = tonumber(ar.min_change_interval_s or 2.0) or 2.0
	if link.autorate.last_apply_at ~= nil and (tnow - link.autorate.last_apply_at) < min_change_interval_s then
		return
	end

	local up_kbit   = link.autorate.current_up_kbit
	local down_kbit = link.autorate.current_down_kbit

	local tx_load = 0
	local rx_load = 0

	if up_kbit > 0 then
		tx_load = (link.counters.tx_bps or 0) / (up_kbit * 1000)
	end
	if down_kbit > 0 then
		rx_load = (link.counters.rx_bps or 0) / (down_kbit * 1000)
	end

	local high_load = tonumber(ar.high_load_level or 0.80) or 0.80
	local delay_bad = tonumber(ar.max_delay_ms or 15) or 15

	if link.health.state == 'offline' then
		-- If the link is offline, do not churn shaping. Keep the last rate.
		link.autorate.reason = 'offline_hold'
		return
	elseif link.health.state == 'degraded' or (link.health.delay_rtt_ms or 0) > delay_bad then
		up_kbit   = math.floor(up_kbit   * 0.90)
		down_kbit = math.floor(down_kbit * 0.90)
		link.autorate.reason = 'decrease_due_to_delay'
	elseif tx_load >= high_load or rx_load >= high_load then
		up_kbit   = math.floor(up_kbit   * 1.05)
		down_kbit = math.floor(down_kbit * 1.05)
		link.autorate.reason = 'increase_due_to_load'
	else
		link.autorate.reason = 'hold'
	end

	link.autorate.current_up_kbit   = clamp_num(up_kbit,   min_up,   max_up)
	link.autorate.current_down_kbit = clamp_num(down_kbit, min_down, max_down)
end

local function build_live_shaper_request(model)
	-- Convert current per-link autorate outputs into a HAL request.
	--
	-- HAL should interpret this request as "apply live shaping only", not as a
	-- structural reconcile. In particular, the implementation should avoid
	-- restarting unrelated network services.
	local req = { links = {} }

	for link_id, link in pairs(model.links) do
		local sh = link.spec.shaping or {}
		if sh.enabled == true then
			req.links[link_id] = {
				mode       = sh.mode or 'cake',
				scope      = sh.scope or 'wan',
				up_kbit    = link.autorate.current_up_kbit,
				down_kbit  = link.autorate.current_down_kbit,
				overhead   = sh.overhead,
				mpu        = sh.mpu,
				ingress_ifb = sh.ingress_ifb,
			}
		end
	end

	return req
end

--------------------------------------------------------------------------------
-- Live multiwan control
--------------------------------------------------------------------------------

local function compute_live_weights_stub(model)
	-- This is the NET-owned multiwan judgement.
	--
	-- The real version should eventually support:
	--   * state-aware exclusion / inclusion
	--   * degraded links staying in service at lower weight
	--   * capacity-derived dynamic weighting
	--   * minimum update interval / hysteresis
	--   * family-specific behaviour (IPv4/IPv6)
	--
	-- For now:
	--   * offline links are removed from the active member set
	--   * online links keep their configured base weight
	--   * degraded links stay active but at weight 1
	local mp = model.bundle.runtime.multipath or {}
	local active = {}

	for link_id, link in pairs(model.links) do
		local spec = link.spec.multipath or {}
		if spec.participate ~= false then
			if link.health.state == 'online' then
				link.multipath.live_member = true
				link.multipath.live_weight = tonumber(spec.base_weight or 1) or 1
			elseif link.health.state == 'degraded' then
				link.multipath.live_member = true
				link.multipath.live_weight = 1
			else
				link.multipath.live_member = false
				link.multipath.live_weight = 0
			end

			if link.multipath.live_member then
				active[#active + 1] = {
					link_id = link_id,
					metric  = tonumber(spec.metric or 1) or 1,
					weight  = math.max(1, math.floor(link.multipath.live_weight or 1)),
				}
			end
		end
	end

	table.sort(active, function(a, b)
		if a.metric ~= b.metric then return a.metric < b.metric end
		return tostring(a.link_id) < tostring(b.link_id)
	end)

	-- Keep only the best currently active metric tier, matching mwan3 semantics.
	local chosen = {}
	local best_metric = nil
	for i = 1, #active do
		local rec = active[i]
		if best_metric == nil then best_metric = rec.metric end
		if rec.metric == best_metric then
			chosen[#chosen + 1] = rec
		end
	end

	return {
		policy      = mp.policy_name or 'default',
		last_resort = mp.last_resort or 'unreachable',
		members     = chosen,
	}
end

local function build_persist_multipath_request(model, live_req)
	-- Persistence is deliberately separate from live apply.
	--
	-- The live request describes what the dataplane should do *now*.
	-- The persist request describes what should be written back into OS config so
	-- that a future network restart or reboot re-enters a sensible state.
	--
	-- This request should generally be called less often than live apply.
	local req = {
		policy      = live_req.policy,
		last_resort = live_req.last_resort,
		members     = {},
	}

	for i = 1, #(live_req.members or {}) do
		local rec = live_req.members[i]
		req.members[#req.members + 1] = {
			link_id = rec.link_id,
			metric  = rec.metric,
			weight  = rec.weight,
		}
	end

	return req
end

--------------------------------------------------------------------------------
-- Control pass
--------------------------------------------------------------------------------

local function run_control_pass(conn, svc, model)
	-- This function is where NET turns raw/derived observations into decisions.
	--
	-- Order matters:
	--   1. classify link health
	--   2. update per-link autorate outputs
	--   3. derive desired live shaper request
	--   4. derive desired live multipath request
	--   5. apply only if request signatures changed
	local tnow = now()

	for link_id, link in pairs(model.links) do
		classify_link_health_stub(link, tnow)
		compute_autorate_stub(link, tnow)
		publish_link_state_stub(conn, svc, link_id, link)
	end

	-- Live shaper request.
	local shaper_req = build_live_shaper_request(model)
	local shaper_sig = stable_sig(shaper_req)

	if shaper_sig ~= model.last_shaper_sig then
		local reply, err = svc:hal_call('apply_link_shaping_live', shaper_req, 10.0)
		if not reply or reply.ok ~= true then
			svc:obs_log('warn', {
				what = 'live_shaper_apply_failed',
				err  = tostring((reply and reply.err) or err),
			})
		else
			model.last_shaper_sig = shaper_sig
			for _, link in pairs(model.links) do
				if (link.spec.shaping or {}).enabled == true then
					link.autorate.last_apply_at = tnow
				end
			end
		end
	end

	-- Live multiwan request.
	local mp_req = compute_live_weights_stub(model)
	local mp_sig = stable_sig(mp_req)

	if mp_sig ~= model.last_multipath_sig then
		local reply, err = svc:hal_call('apply_multipath_live', mp_req, 10.0)
		if not reply or reply.ok ~= true then
			svc:obs_log('warn', {
				what = 'live_multipath_apply_failed',
				err  = tostring((reply and reply.err) or err),
			})
		else
			model.last_multipath_sig = mp_sig

			-- Only schedule persistence after a successful live apply.
			-- The quiet period avoids churny config rewrites when link quality is
			-- changing rapidly.
			local quiet_s = tonumber((model.bundle.runtime.timings or {}).persist_quiet_s or 30.0) or 30.0
			mark_persist_dirty(model, tnow + quiet_s)

			for _, link in pairs(model.links) do
				link.multipath.last_apply_at = tnow
			end
		end
	end

	model.control.dirty   = false
	model.control.next_at = tnow + (model.bundle.runtime.timings.control_interval_s or 1.0)
end

--------------------------------------------------------------------------------
-- Structural apply
--------------------------------------------------------------------------------

local function run_structural_apply(svc, model, cfg_rev)
	-- This remains your existing path:
	--   compiler.desired -> rpc/hal/apply_net
	local req = {
		gen     = model.bundle.gen,
		rev     = cfg_rev,
		desired = model.bundle.desired,
	}

	local reply, err = svc:hal_call('apply_net', req, 15.0)

	if not reply then
		svc:obs_log('warn', {
			what = 'apply_call_failed',
			err  = tostring(err),
			gen  = model.bundle.gen,
			rev  = cfg_rev,
		})
		model.structural.next_apply_at = now() + model.structural.retry_s
		model.structural.retry_s = math.min(model.structural.retry_s * 2, model.structural.retry_max_s)
		return false
	end

	local ok      = (reply.ok == true)
	local applied = (reply.applied == true)
	local changed = (reply.changed == true) or (reply.changed == nil and applied)

	svc:obs_event('apply_end', {
		gen     = model.bundle.gen,
		rev     = cfg_rev,
		applied = applied,
		changed = changed,
		ok      = ok,
		err     = (not ok) and tostring(reply.err or 'apply failed') or nil,
	})

	if ok then
		model.structural.dirty   = false
		model.structural.next_apply_at = inf()
		model.structural.retry_s = 1.0
		return true
	end

	model.structural.next_apply_at = now() + model.structural.retry_s
	model.structural.retry_s = math.min(model.structural.retry_s * 2, model.structural.retry_max_s)
	return false
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

local function run_persist_pass(svc, model)
	local live_req = compute_live_weights_stub(model)
	local persist_req = build_persist_multipath_request(model, live_req)
	local sig = stable_sig(persist_req)

	if sig == model.persist.last_sig then
		model.persist.dirty   = false
		model.persist.next_at = inf()
		return
	end

	local reply, err = svc:hal_call('persist_multipath_state', persist_req, 10.0)
	if not reply or reply.ok ~= true then
		svc:obs_log('warn', {
			what = 'persist_multipath_failed',
			err  = tostring((reply and reply.err) or err),
		})
		model.persist.next_at = now() + 30.0
		return
	end

	model.persist.last_sig = sig
	model.persist.dirty    = false
	model.persist.next_at  = inf()
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'net', env = opts.env })

	svc:status('starting')
	svc:obs_log('info', { what = 'start_entered' })

	-- Wait for HAL announce exactly as you already do.
	local hal_announce, herr = svc:wait_for_hal({ timeout = 60, tick = 10 })
	if not hal_announce then
		svc:status('stopped', { reason = herr })
		svc:obs_log('error', { what = 'start_failed', err = tostring(herr) })
		return
	end

	svc:status('running', { hal_backend = hal_announce.backend })
	svc:obs_event('ready', { hal_backend = hal_announce.backend })

	-- We still drive everything from config/net.
	-- The only change is that compilation now yields a structural product and a
	-- NET-local runtime policy product.
	local sub_cfg = conn:subscribe({ 'config', 'net' }, { queue_len = 10, full = 'drop_oldest' })

	local cfg_data = nil
	local cfg_rev  = 0
	local model    = nil
	local gen      = 0

	-- Wait for first retained config exactly as before, but compile the bundle.
	while cfg_data == nil do
		local msg, err = perform(sub_cfg:recv_op())
		if not msg then
			svc:status('stopped', { reason = err })
			svc:obs_log('warn', { what = 'config_subscription_ended', err = tostring(err) })
			return
		end

		local p = msg.payload
		if type(p) == 'table' and type(p.rev) == 'number' and type(p.data) == 'table' then
			cfg_data = p.data
			cfg_rev  = math.floor(p.rev)
			gen      = gen + 1

			local bundle, diag = compile_bundle_from_config(cfg_data, cfg_rev, gen)
			if not bundle then
				svc:obs_log('error', { what = 'compile_failed', diag = diag })
			else
				model = build_runtime_model(bundle)
				svc:obs_event('config_update', { ts = svc:now(), at = svc:wall(), rev = cfg_rev })
			end
		else
			svc:obs_log('warn', { what = 'bad_config_payload', kind = type(p) })
		end
	end

	if model == nil then
		svc:status('stopped', { reason = 'initial compile failed' })
		return
	end

	while true do
		local tnow = now()

		-- Compute the next timer deadline from all runtime domains.
		local next_timer_at = min_deadline(
			model.structural.dirty and model.structural.next_apply_at or inf(),
			model.inventory.dirty  and model.inventory.next_at        or inf(),
			model.probing.dirty    and model.probing.next_at          or inf(),
			model.counters.dirty   and model.counters.next_at         or inf(),
			model.control.dirty    and model.control.next_at          or inf(),
			model.persist.dirty    and model.persist.next_at          or inf()
		)

		local arms = {
			cfg = sub_cfg:recv_op(),
		}

		if next_timer_at < inf() then
			local dt = next_timer_at - tnow
			if dt < 0 then dt = 0 end
			arms.timer = sleep.sleep_op(dt):wrap(function() return true end)
		end

		local which, a, b = perform(named_choice(arms))

		if which == 'cfg' then
			local msg, err = a, b
			if not msg then
				svc:status('stopped', { reason = err })
				svc:obs_log('warn', { what = 'config_subscription_ended', err = tostring(err) })
				return
			end

			local p = msg.payload
			if type(p) == 'table' and type(p.rev) == 'number' and type(p.data) == 'table' then
				local rev = math.floor(p.rev)
				if rev > cfg_rev then
					cfg_data = p.data
					cfg_rev  = rev
					gen      = gen + 1

					local bundle, diag = compile_bundle_from_config(cfg_data, cfg_rev, gen)
					if not bundle then
						svc:obs_log('error', { what = 'compile_failed', diag = diag, rev = cfg_rev })
					else
						merge_bundle_into_model(model, bundle)
						svc:obs_event('config_update', { ts = svc:now(), at = svc:wall(), rev = cfg_rev })
					end
				end
			else
				svc:obs_log('warn', { what = 'bad_config_payload', kind = type(p) })
			end
		else
			local tick_now = now()

			if model.structural.dirty and tick_now >= model.structural.next_apply_at then
				svc:obs_event('apply_begin', { gen = model.bundle.gen, rev = cfg_rev })
				local ok = run_structural_apply(svc, model, cfg_rev)
				if ok then
					svc:status('running', { last_applied_rev = cfg_rev, last_applied_gen = model.bundle.gen })
					-- Once the structural state is in place, refresh inventory and runtime
					-- observations promptly, because devices and routes may have changed.
					mark_inventory_dirty(model, now())
					mark_probe_dirty(model, now())
					mark_counter_dirty(model, now())
					mark_control_dirty(model, now())
				end
			end

			if model.inventory.dirty and tick_now >= model.inventory.next_at then
				refresh_inventory(svc, model)
			end

			if model.probing.dirty and tick_now >= model.probing.next_at then
				run_probe_round(svc, model)
			end

			if model.counters.dirty and tick_now >= model.counters.next_at then
				run_counter_sample(svc, model)
			end

			if model.control.dirty and tick_now >= model.control.next_at then
				run_control_pass(conn, svc, model)
			end

			if model.persist.dirty and tick_now >= model.persist.next_at then
				run_persist_pass(svc, model)
			end
		end
	end
end

return M
