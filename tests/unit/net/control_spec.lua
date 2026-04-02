-- tests/net_control_spec.lua

local control = require 'services.net.control'

local T = {}

function T.classify_link_health_offline_on_stale_probe()
	local link = {
		spec = {
			health = {
				interval_s = 2,
				stale_after_s = 6,
				down = 2,
				failure_delay_ms = 150,
				failure_loss_pct = 40,
			},
		},
		probe = {
			last_reply_at = 10,
		},
		health = {
			state = 'unknown',
			failure_streak = 0,
			delay_rtt_ms = 0,
			loss_pct_ewma = 0,
		},
	}

	control.classify_link_health(link, 17.1)
	assert(link.health.state == 'offline')
	assert(link.health.reason == 'stale_probes')
end

function T.classify_link_health_degraded_on_delay()
	local link = {
		spec = {
			health = {
				interval_s = 2,
				stale_after_s = 6,
				down = 2,
				failure_delay_ms = 100,
				failure_loss_pct = 40,
			},
		},
		probe = {
			last_reply_at = 10,
		},
		health = {
			state = 'unknown',
			failure_streak = 0,
			delay_rtt_ms = 120,
			loss_pct_ewma = 0,
		},
	}

	control.classify_link_health(link, 12)
	assert(link.health.state == 'degraded')
	assert(link.health.reason == 'high_delay')
end

function T.stable_sig_is_order_independent()
	local a = { x = 1, y = { b = 2, a = 1 } }
	local b = { y = { a = 1, b = 2 }, x = 1 }
	assert(control.stable_sig(a) == control.stable_sig(b))
end

return T
