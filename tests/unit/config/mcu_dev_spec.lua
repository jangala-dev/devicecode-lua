-- tests/unit/config/mcu_dev_spec.lua

local cjson = require 'cjson.safe'

local fabric_config = require 'services.fabric.config'
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
	assert_eq(fabric.links[1].transport.source, 'uart_manager')
	assert_eq(fabric.links[1].transfer.chunk_size, 2048)

	local cat, derr = device_config.to_catalogue(raw.device.data)
	assert_not_nil(cat, derr)
	assert_not_nil(cat.components.mcu.actions['stage-update'])

	local update, uerr = update_config.normalise(raw.update.data)
	assert_not_nil(update, uerr)
	assert_eq(update.components.mcu.backend, 'device_component')
end

return tests
