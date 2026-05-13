-- tests/unit/device/test_publisher.lua

local config = require 'services.device.config'
local model_mod = require 'services.device.model'
local publisher = require 'services.device.publisher'
local topics = require 'services.device.topics'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end

local function key(topic) return table.concat(topic, '/') end

local function fake_conn()
	local c = { retained = {}, published = {} }
	function c:retain(topic, payload) self.retained[key(topic)] = payload; return true end
	function c:unretain(topic) self.retained[key(topic)] = nil; return true end
	function c:publish(topic, payload) self.published[#self.published + 1] = { topic = topic, payload = payload }; return true end
	return c
end

function tests.test_publish_component_and_summary_are_immediate_effects()
	local cat = assert(config.to_catalogue({
		schema = config.SCHEMA,
		components = {
			mcu = { subtype = 'mcu', facts = { software = topics.raw_member_state('mcu', 'software') } },
		},
	}))
	local m = model_mod.new()
	m:apply_catalogue(1, cat)
	m:apply_observation(1, { component = 'mcu', tag = 'fact_retained', fact = 'software', payload = { version = '1.0' } })

	local conn = fake_conn()
	local snap = m:snapshot()
	local ok, err = publisher.publish_component_now(conn, snap, 'mcu', { now = function () return 123 end })
	assert_true(ok, err)
	assert_eq(conn.retained['state/device/component/mcu'].component, 'mcu')
	assert_eq(conn.retained['state/device/component/mcu/software'].version, '1.0')
	assert_eq(conn.retained['cap/component/mcu/status'].state, 'available')

	ok, err = publisher.publish_summary_now(conn, snap, { now = function () return 123 end })
	assert_true(ok, err)
	assert_eq(conn.retained['state/device/components'].counts.total, 1)
end

return tests
