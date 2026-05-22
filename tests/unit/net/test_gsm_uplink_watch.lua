-- tests/unit/net/test_gsm_uplink_watch.lua

local watch = require 'services.net.gsm_uplink_watch'

local tests = {}
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end
local function eq(a, b, msg) if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end

function tests.test_maps_canonical_retained_event()
	local ev = watch._test.map_event({ op = 'retain', topic = { 'state', 'gsm', 'uplink', 'primary' }, payload = { connected = true, linux = { ifname = 'wwan1' } } })
	eq(ev.kind, 'gsm_uplink_changed')
	eq(ev.role, 'primary')
	eq(ev.payload.schema, 'devicecode.gsm.uplink/1')
	eq(ev.payload.linux.ifname, 'wwan1')
end

function tests.test_maps_unretain_to_unavailable_state()
	local ev = watch._test.map_event({ op = 'unretain', topic = { 'state', 'gsm', 'uplink', 'secondary' } })
	eq(ev.kind, 'gsm_uplink_changed')
	eq(ev.role, 'secondary')
	eq(ev.payload.state, 'unavailable')
	eq(ev.payload.connected, false)
end

function tests.test_maps_replay_done()
	local ev = watch._test.map_event({ op = 'replay_done' })
	eq(ev.kind, 'gsm_uplink_replay_done')
end

function tests.test_malformed_topic_is_unknown()
	local ev = watch._test.map_event({ op = 'retain', topic = { 'state', 'gsm', 'modem', 'primary', 'uplink' }, payload = {} })
	eq(ev.kind, 'gsm_uplink_unknown')
end

return tests
