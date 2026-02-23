package.path = "../src/lua-fibers/?.lua;" -- fibers submodule src
    .. "../src/lua-trie/src/?.lua;"       -- trie submodule src
    .. "../src/lua-bus/src/?.lua;"        -- bus submodule src
    .. "../src/?.lua;"
    .. "./test_utils/?.lua;"
    .. package.path
    .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

local fiber = require "fibers.fiber"
local context = require "fibers.context"

local function test_uim_get_gids_simple()
    -- Clear cached module
    package.loaded["services.hal.drivers.modem.mode.qmi"] = nil

    -- Mock dependencies
    local mock_context = {
        with_timeout = function(ctx, timeout)
            return ctx
        end
    }

    local mock_cmd = {
        setpgid_called = false,
        setpgid = function(self, val)
            self.setpgid_called = true
        end,
        combined_output = function(self)
            local output = [[
[/dev/cdc-wdm1] Successfully read information from the UIM:
Card result:
        SW1: '0x90'
        SW2: '0x00'
Read result:
        FF]]
            return output, nil
        end
    }

    local mock_qmicli = {
        uim_read_transparent = function(ctx, port, id)
            return mock_cmd
        end
    }

    local mock_wraperr = {
        new = function(err) return err end
    }

    -- Load the qmi module with mocked dependencies
    package.loaded["services.hal.drivers.modem.qmicli"] = mock_qmicli
    package.loaded["fibers.context"] = mock_context
    package.loaded["wraperr"] = mock_wraperr
    package.loaded["services.hal.utils"] = require("services.hal.utils")
    package.loaded["services.log"] = require("services.log")

    local qmi_module = require("services.hal.drivers.modem.mode.qmi")

    -- Create a mock modem object
    local modem = {
        ctx = context.background(),
        primary_port = "/dev/cdc-wdm1"
    }

    -- Initialize the modem with qmi functions
    qmi_module(modem)

    -- Test the function
    local gids, err = modem.uim_get_gids()

    assert(err == nil, "expected err to be nil but got " .. tostring(err))
    assert(gids ~= nil, "expected gids to be a table but got nil")
    assert(gids.gid1 == "FF", "expected gid1 to be 'FF' but got '" .. tostring(gids.gid1) .. "'")
    assert(mock_cmd.setpgid_called, "expected setpgid to be called")
end

local function test_uim_get_gids_complex()
    -- Clear cached module
    package.loaded["services.hal.drivers.modem.mode.qmi"] = nil

    -- Mock dependencies
    local mock_context = {
        with_timeout = function(ctx, timeout)
            return ctx
        end
    }

    local mock_cmd = {
        setpgid_called = false,
        setpgid = function(self, val)
            self.setpgid_called = true
        end,
        combined_output = function(self)
            local output = [[
[/dev/cdc-wdm1] Successfully read information from the UIM:
Card result:
	SW1: '0x90'
	SW2: '0x00'
Read result:
	85:FF:FF:FF:FF:FF:47:45:4E:49:45:49:4E:20:20:20:20:20:20:20]]
            return output, nil
        end
    }

    local mock_qmicli = {
        uim_read_transparent = function(ctx, port, id)
            return mock_cmd
        end
    }

    local mock_wraperr = {
        new = function(err) return err end
    }

    -- Load the qmi module with mocked dependencies
    package.loaded["services.hal.drivers.modem.qmicli"] = mock_qmicli
    package.loaded["fibers.context"] = mock_context
    package.loaded["wraperr"] = mock_wraperr
    package.loaded["services.hal.utils"] = require("services.hal.utils")
    package.loaded["services.log"] = require("services.log")

    local qmi_module = require("services.hal.drivers.modem.mode.qmi")

    -- Create a mock modem object
    local modem = {
        ctx = context.background(),
        primary_port = "/dev/cdc-wdm1"
    }

    -- Initialize the modem with qmi functions
    qmi_module(modem)

    -- Test the function
    local gids, err = modem.uim_get_gids()

    assert(err == nil, "expected err to be nil but got " .. tostring(err))
    assert(gids ~= nil, "expected gids to be a table but got nil")

    local expected = "85FFFFFFFFFF47454E4945494E20202020202020"
    assert(gids.gid1 == expected,
        "expected gid1 to be '" .. expected .. "' but got '" .. tostring(gids.gid1) .. "'")
    assert(mock_cmd.setpgid_called, "expected setpgid to be called")
end

local function test_uim_get_gids_error()
    -- Clear cached module
    package.loaded["services.hal.drivers.modem.mode.qmi"] = nil

    -- Mock dependencies
    local mock_context = {
        with_timeout = function(ctx, timeout)
            return ctx
        end
    }

    local mock_cmd = {
        setpgid_called = false,
        setpgid = function(self, val)
            self.setpgid_called = true
        end,
        combined_output = function(self)
            return "", "command failed"
        end
    }

    local mock_qmicli = {
        uim_read_transparent = function(ctx, port, id)
            return mock_cmd
        end
    }

    local mock_wraperr = {
        new = function(err) return "wrapped: " .. err end
    }

    -- Load the qmi module with mocked dependencies
    package.loaded["services.hal.drivers.modem.qmicli"] = mock_qmicli
    package.loaded["fibers.context"] = mock_context
    package.loaded["wraperr"] = mock_wraperr
    package.loaded["services.hal.utils"] = require("services.hal.utils")
    package.loaded["services.log"] = require("services.log")

    local qmi_module = require("services.hal.drivers.modem.mode.qmi")

    -- Create a mock modem object
    local modem = {
        ctx = context.background(),
        primary_port = "/dev/cdc-wdm1"
    }

    -- Initialize the modem with qmi functions
    qmi_module(modem)

    -- Test the function
    local gids, err = modem.uim_get_gids()

    assert(err ~= nil, "expected err to be set but got nil")
    assert(err == "wrapped: command failed", "expected wrapped error but got " .. tostring(err))
    assert(gids ~= nil, "expected gids to be a table but got nil")
    assert(next(gids) == nil, "expected gids to be empty but it has values")
end

fiber.spawn(function ()
    test_uim_get_gids_simple()
    test_uim_get_gids_complex()
    test_uim_get_gids_error()
    fiber.stop()
end)

print("running hal qmi tests")
fiber.main()
print("passed")
