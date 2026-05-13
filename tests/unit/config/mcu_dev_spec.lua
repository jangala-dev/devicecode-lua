-- tests/unit/config/mcu_dev_spec.lua

local cjson = require 'cjson.safe'

local fabric_config = require 'services.fabric.config'
local fabric_topics = require 'services.fabric.topics'
local device_config = require 'services.device.config'
local update_config = require 'services.update.config'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

local function read_file(path)
	local f, err = io.open(path, 'rb')
	assert_not_nil(f, err)
	local s = f:read('*a')
	f:close()
	return s
end

function tests.test_mcu_dev_config_sections_compile()
	local raw, err = cjson.decode(read_file('../src/configs/mcu-dev.json'))
	assert_not_nil(raw, err)

	assert_eq(raw.hal.data.schema, 'devicecode.config/hal/1')
	assert_not_nil(raw.hal.data.uart[1])
	assert_eq(raw.hal.data.uart[1].id, 'uart-0')
	assert_not_nil(raw.hal.data.artifact_store)
	assert_not_nil(raw.hal.data.control_store[1])

	local fabric, ferr = fabric_config.compile(raw.fabric.data)
	assert_not_nil(fabric, ferr)
	assert_eq(fabric.links[1].transport.source, 'uart_uart-0')
	assert_eq(fabric.links[1].transfer.chunk_size, 1024)
	assert_eq(#fabric.links[1].bridge.import_rules, 2)
	assert_eq(table.concat(fabric.links[1].bridge.import_rules[1].local_prefix, '/'), 'raw/member/mcu/state')
	assert_eq(table.concat(fabric.links[1].bridge.import_rules[1].remote_prefix, '/'), 'state/self')
	local software_topic = fabric_topics.map_remote_to_local(fabric.links[1].bridge.import_rules, { 'state', 'self', 'software' })
	assert_eq(table.concat(software_topic, '/'), 'raw/member/mcu/state/software')
	assert_eq(#fabric.links[1].bridge.outbound_call_rules, 2)
	assert_eq(table.concat(fabric.links[1].bridge.outbound_call_rules[1].local_topic, '/'), 'raw/member/mcu/cmd/self/updater/prepare')
	assert_eq(table.concat(fabric.links[1].bridge.outbound_call_rules[1].remote_topic, '/'), 'cmd/self/updater/prepare')
	assert_eq(table.concat(fabric.links[1].bridge.outbound_call_rules[2].local_topic, '/'), 'raw/member/mcu/cmd/self/updater/commit')
	assert_eq(table.concat(fabric.links[1].bridge.outbound_call_rules[2].remote_topic, '/'), 'cmd/self/updater/commit')

	local cat, derr = device_config.to_catalogue(raw.device.data)
	assert_not_nil(cat, derr)
	assert_not_nil(cat.components.mcu.actions['prepare-update'])
	assert_not_nil(cat.components.mcu.actions['stage-update'])
	assert_eq(cat.components.mcu.actions['stage-update'].target, 'updater/main')
	assert_eq(cat.components.mcu.actions['stage-update'].timeout, 900.0)
	assert_not_nil(cat.components.mcu.actions['commit-update'])

	local update, uerr = update_config.normalise(raw.update.data)
	assert_not_nil(update, uerr)
	assert_eq(update.components.mcu.backend, 'device_component')
end

return tests
