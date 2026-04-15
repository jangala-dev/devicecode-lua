-- services/net/control.lua
--
-- NET control helpers and HAL-facing passes.

local runtime = require 'fibers.runtime'

local M = {}

local function now()
	return runtime.now()
end

local function clamp_num(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

function M.stable_sig(v)
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
		parts[#parts + 1] = M.stable_sig(k)
		parts[#parts + 1] = '='
		parts[#parts + 1] = M.stable_sig(v[k])
		parts[#parts + 1] = ';'
	end
	parts[#parts + 1] = '}'
	return table.concat(parts)
end

function M.publish_link_state(conn, svc, link_id, link)
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

function M.refresh_inventory(svc, model, mark_control_dirty)
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

	mark_control_dirty(model, now())
end

function M.due_probe_links(model, tnow)
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

function M.ingest_probe_sample(link, sample, tnow)
	link.probe.last_reply_at = tnow

	if sample and sample.ok == true and type(sample.rtt_ms) == 'number' then
		local rtt = tonumber(sample.rtt_ms)

		link.health.success_streak = (link.health.success_streak or 0) + 1
		link.health.failure_streak = 0

		if link.health.baseline_rtt_ms == nil then
			link.health.baseline_rtt_ms = rtt
		else
			local alpha_base = ((link.spec.health or {}).baseline_alpha) or 0.05
			local old = link.health.baseline_rtt_ms
			local nextv = old * (1 - alpha_base) + rtt * alpha_base
			if rtt < nextv then nextv = rtt end
			link.health.baseline_rtt_ms = nextv
		end

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

function M.run_probe_round(svc, model, mark_control_dirty)
	local tnow = now()
	local due = M.due_probe_links(model, tnow)

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
			method     = hs.method or 'ping',
			reflectors = hs.reflectors or {},
			timeout_s  = hs.timeout_s or 2.0,
			count      = hs.count or 1,
		}

		link.probe.round        = (link.probe.round or 0) + 1
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
			M.ingest_probe_sample(link, sample, tnow)
			local interval_s = ((link.spec.health or {}).interval_s) or (model.bundle.runtime.timings.probe_interval_s or 2.0)
			link.probe.next_at = tnow + interval_s
		end
	end

	model.probing.dirty   = false
	model.probing.next_at = tnow + 0.50
	model.probing.retry_s = 1.0

	mark_control_dirty(model, now())
end

function M.run_counter_sample(svc, model, mark_control_dirty)
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

function M.classify_link_health(link, tnow)
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

function M.compute_autorate(link, tnow)
	local sh = link.spec.shaping or {}
	if sh.enabled ~= true then
		return
	end

	local ar = sh.autorate or {}
	local min_up   = tonumber(ar.min_up_kbit or sh.static_up_kbit or 1000) or 1000
	local max_up   = tonumber(ar.max_up_kbit or sh.static_up_kbit or min_up) or min_up
	local min_down = tonumber(ar.min_down_kbit or sh.static_down_kbit or 1000) or 1000
	local max_down = tonumber(ar.max_down_kbit or sh.static_down_kbit or min_down) or min_down

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

function M.build_live_shaper_request(model)
	local req = { links = {} }

	for link_id, link in pairs(model.links) do
		local sh = link.spec.shaping or {}
		if sh.enabled == true then
			req.links[link_id] = {
				mode        = sh.mode or 'cake',
				scope       = sh.scope or 'wan',
				up_kbit     = link.autorate.current_up_kbit,
				down_kbit   = link.autorate.current_down_kbit,
				overhead    = sh.overhead,
				mpu         = sh.mpu,
				ingress_ifb = sh.ingress_ifb,
			}
		end
	end

	return req
end

function M.compute_live_weights(model)
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

function M.build_persist_multipath_request(live_req)
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

function M.run_control_pass(conn, svc, model, mark_persist_dirty)
	local tnow = now()

	for link_id, link in pairs(model.links) do
		M.classify_link_health(link, tnow)
		M.compute_autorate(link, tnow)
		M.publish_link_state(conn, svc, link_id, link)
	end

	local shaper_req = M.build_live_shaper_request(model)
	local shaper_sig = M.stable_sig(shaper_req)

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

	local mp_req = M.compute_live_weights(model)
	local mp_sig = M.stable_sig(mp_req)

	if mp_sig ~= model.last_multipath_sig then
		local reply, err = svc:hal_call('apply_multipath_live', mp_req, 10.0)
		if not reply or reply.ok ~= true then
			svc:obs_log('warn', {
				what = 'live_multipath_apply_failed',
				err  = tostring((reply and reply.err) or err),
			})
		else
			model.last_multipath_sig = mp_sig

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

function M.run_structural_apply(svc, model)
	local req = {
		gen     = model.bundle.gen,
		rev     = model.bundle.rev,
		desired = model.bundle.desired,
	}

	local reply, err = svc:hal_call('apply_net', req, 15.0)

	if not reply then
		svc:obs_log('warn', {
			what = 'apply_call_failed',
			err  = tostring(err),
			gen  = model.bundle.gen,
			rev  = model.bundle.rev,
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
		rev     = model.bundle.rev,
		applied = applied,
		changed = changed,
		ok      = ok,
		err     = (not ok) and tostring(reply.err or 'apply failed') or nil,
	})

	if ok then
		model.structural.dirty   = false
		model.structural.next_apply_at = math.huge
		model.structural.retry_s = 1.0
		return true
	end

	model.structural.next_apply_at = now() + model.structural.retry_s
	model.structural.retry_s = math.min(model.structural.retry_s * 2, model.structural.retry_max_s)
	return false
end

function M.run_persist_pass(svc, model)
	local live_req = M.compute_live_weights(model)
	local persist_req = M.build_persist_multipath_request(live_req)
	local sig = M.stable_sig(persist_req)

	if sig == model.persist.last_sig then
		model.persist.dirty   = false
		model.persist.next_at = math.huge
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
	model.persist.next_at  = math.huge
end

return M
