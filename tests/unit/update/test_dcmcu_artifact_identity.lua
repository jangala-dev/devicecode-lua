local fibers = require 'fibers'
local blob_source = require 'devicecode.blob_source'
local dcmcu = require 'services.update.artifacts.dcmcu'
local fixture = require 'tests.support.dcmcu_fixture'

local T = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

function T.parses_dcmcu_v1_identity_from_source()
	fibers.run(function ()
		local raw = fixture.make('mcu-image-new', 'abc', { version = '15.0', build_id = 'build-15' })
		local identity, err = fibers.perform(dcmcu.identity_from_source_op(blob_source.from_string(raw)))
		assert_not_nil(identity, tostring(err))
		assert_eq(identity.format, 'dcmcu-v1')
		assert_eq(identity.component, 'mcu')
		assert_eq(identity.image_id, 'mcu-image-new')
		assert_eq(identity.version, '15.0')
		assert_eq(identity.build_id, 'build-15')
		assert_eq(identity.payload_length, 3)
	end)
end

function T.rejects_non_dcmcu_payload()
	fibers.run(function ()
		local identity, err = fibers.perform(dcmcu.identity_from_source_op(blob_source.from_string('not a dcmcu')))
		assert_eq(identity, nil)
		assert_not_nil(err)
	end)
end

return T
