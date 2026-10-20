local fibers = require 'fibers'
local file = require 'fibers.io.file'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local safe = require 'coxpcall'
local pty = require 'tests.support.pty'
local runfibers = require 'tests.support.run_fibers'
local at = require 'services.hal.backends.modem.at'
local quectel = require 'services.hal.backends.modem.models.quectel'

local tests = {}

---@param body fun(scope: Scope, port: TestPTY, streams: Stream[]): nil
---@return nil
local function with_port(body)
    local saved_open = file.open
    local ok, err = safe.pcall(function()
        runfibers.run(function(scope)
            local port = pty.open()
            scope:finally(function()
                port.master:terminate('test complete')
                port:close()
            end)
            local streams = {}
            file.open = function(path, mode, perms)
                local stream, open_err = saved_open(path, mode, perms)
                if path == port.slave_name and stream then streams[#streams + 1] = stream end
                return stream, open_err
            end
            body(scope, port, streams)
        end)
    end)
    file.open = saved_open
    assert(ok, err)
end

---@param streams Stream[]
---@param count integer
---@return nil
local function assert_closed(streams, count)
    assert(#streams == count, 'unexpected number of AT streams')
    for _, stream in ipairs(streams) do
        local closed, err = fibers.perform(stream:close_op():or_else(function()
            return nil, 'AT stream left open'
        end))
        assert(closed, err)
    end
end

---@return nil
function tests.test_pdp_at_transport_reads_composite_using_real_streams()
    with_port(function(scope, port, streams)
        assert(scope:spawn(function()
            assert(port:expect_exact(12) == 'AT+CGDCONT?\r')
            assert(port:write('\r\n+CGDCONT: 1,"IPV4V6","","",0,0\r\nOK\r\n'))
            assert(port:expect_exact(10) == 'AT+CGACT?\r')
            assert(port:write('\r\n+CGACT: 1,1\r\nOK\r\n'))
        end))
        local backend = { identity = { at_port = port.slave_name } }
        quectel.add_model_funcs(backend, { model = 'em12' })
        local info, err = backend:read_pdp_info()
        assert(info, err)
        assert(#info.pdp_contexts == 1)
        assert(info.pdp_contexts[1].pdp_type == 'IPV4V6')
        assert(info.pdp_contexts[1].active == true)
        assert_closed(streams, 4)
    end)
end

---@return nil
function tests.test_modem_at_transport_preserves_errors_and_closes_streams()
    for _, response in ipairs({ { 'ERROR', 'error' }, { '+CME ERROR: 13', '13' } }) do
        with_port(function(scope, port, streams)
            assert(scope:spawn(function()
                assert(port:expect_exact(10) == 'AT+CGACT?\r')
                assert(port:write('\r\n' .. response[1] .. '\r\n'))
            end))
            local lines, err = fibers.perform(at.send_op(port.slave_name, 'AT+CGACT?'))
            assert(type(lines) == 'table')
            assert(err == response[2], tostring(err))
            assert_closed(streams, 2)
        end)
    end
end

---@return nil
function tests.test_modem_at_transport_timeout_closes_streams_before_retry()
    with_port(function(scope, port, streams)
        assert(scope:spawn(function()
            assert(port:expect_exact(10) == 'AT+CGACT?\r')
            -- The modem is silent for the first request.
            assert(port:expect_exact(10) == 'AT+CGACT?\r')
            assert(port:write('\r\n+CGACT: 1,1\r\nOK\r\n'))
        end))
        local which = fibers.perform(op.named_choice({
            response = at.send_op(port.slave_name, 'AT+CGACT?'),
            timeout = sleep.sleep_op(0.05),
        }))
        assert(which == 'timeout')
        assert_closed(streams, 2)
        local lines, err = fibers.perform(at.send_op(port.slave_name, 'AT+CGACT?'))
        assert(lines, err)
        assert(lines[1] == '+CGACT: 1,1')
        assert_closed(streams, 4)
    end)
end

---@return nil
function tests.test_modem_at_transport_custom_terminal_closes_streams()
    with_port(function(scope, port, streams)
        assert(scope:spawn(function()
            assert(port:expect_exact(8) == 'AT+QGMR\r')
            assert(port:write('\r\nRM520N_01.203.01.203\r\n'))
        end))
        local lines, err = fibers.perform(at.send_op(port.slave_name, 'AT+QGMR', {
            terminal_patterns = { { pattern = '^RM520N_', is_error = false } },
        }))
        assert(lines, err)
        assert(lines[1] == 'RM520N_01.203.01.203')
        assert_closed(streams, 2)
    end)
end

---@return nil
function tests.test_modem_at_transport_write_failures_close_both_streams()
    for _, method in ipairs({ 'write', 'close' }) do
        with_port(function(_, port, streams)
            local open = file.open
            file.open = function(path, mode, perms)
                local stream, err = open(path, mode, perms)
                if path == port.slave_name and mode == 'w' and stream then
                    stream[method] = function() return nil, 'test write failure' end
                end
                return stream, err
            end
            local lines, err = fibers.perform(at.send_op(port.slave_name, 'AT+CGACT?'))
            assert(lines == nil)
            assert(err and err:find('test write failure', 1, true), tostring(err))
            assert_closed(streams, 2)
        end)
    end
end

return tests
