local fibers = require 'fibers'
local provider = require 'services.hal.backends.wired.providers.rtl8380m_http'

local tests = {}
local function assert_true(v,msg) if v ~= true then error(msg or 'expected true',2) end end
local function assert_eq(a,b,msg) if a ~= b then error(msg or ('expected '..tostring(b)..', got '..tostring(a)),2) end end
local function assert_not_nil(v,msg) if v == nil then error(msg or 'expected non-nil',2) end end


function tests.test_wired_manager_provider_ids_are_config_driven()
	local manager = require 'services.hal.managers.wired'
	local ids, err = manager._test.normalise_provider_ids({
		providers = {
			['cm5-local-wired'] = { provider = 'static' },
			['expansion-a'] = { provider = 'static', id = 'expansion-a' },
		},
	})
	assert_not_nil(ids, err)
	assert_eq(#ids, 2)
	assert_eq(ids[1], 'cm5-local-wired')
	assert_eq(ids[2], 'expansion-a')

	ids, err = manager._test.normalise_provider_ids({ providers = {} })
	assert_not_nil(ids, err)
	assert_eq(#ids, 0)
end

function tests.test_rtl8380m_http_stub_is_read_only()
	fibers.run(function ()
		local p = assert(provider.new({ id = 'switch-main' }))
		local snap = fibers.perform(p:snapshot_op({}))
		assert_true(snap.ok)
		assert_eq(snap.provider_id, 'switch-main')
		assert_true(snap.status.stub)
		local res = fibers.perform(p:apply_attachments_op({}))
		assert_eq(res.code, 'read_only')
		assert_not_nil(res.err)
	end)
end

return tests
