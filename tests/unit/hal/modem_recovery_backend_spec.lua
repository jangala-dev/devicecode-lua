local contract = require 'services.hal.backends.modem.contract'
local linux_mm = require 'services.hal.backends.modem.providers.linux_mm.impl'

local tests = {}

local function eq(actual, expected, message)
    assert(actual == expected, message or ('expected ' .. tostring(expected) .. ', got ' .. tostring(actual)))
end

function tests.test_recovery_device_path_survives_missing_identity_ports()
    local modem_info, parse_err = linux_mm._test.parse_modem_info_json([[
{
  "modem": {
    "generic": {
      "device": "/sys/devices/platform/usb1/1-1",
      "ports": []
    }
  }
}
]])
    assert(modem_info, parse_err)

    local device, err = linux_mm._test.get_device_from_modem_info(modem_info)
    eq(device, '/sys/devices/platform/usb1/1-1')
    eq(err, '')
end

function tests.test_recovery_device_path_rejects_missing_or_empty_value()
    local device, err = linux_mm._test.get_device_from_modem_info({})
    eq(device, nil)
    assert(tostring(err):match('device path'))

    device, err = linux_mm._test.get_device_from_modem_info({ device = '' })
    eq(device, nil)
    assert(tostring(err):match('device path'))
end

function tests.test_recovery_contract_requires_get_device_and_reset()
    local valid = {
        get_device = function() end,
        reset = function() end,
    }
    eq(contract.validate_recovery(valid), '')

    eq(
        contract.validate_recovery({ reset = function() end }),
        'Missing required function: get_device'
    )
    eq(
        contract.validate_recovery({ get_device = function() end }),
        'Missing required function: reset'
    )
end

function tests.test_recovery_contract_rejects_unsupported_functions()
    local backend = {
        get_device = function() end,
        reset = function() end,
        enable = function() end,
    }

    eq(contract.validate_recovery(backend), 'Object provides unsupported function: enable')
end

return tests
