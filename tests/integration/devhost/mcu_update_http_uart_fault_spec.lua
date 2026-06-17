-- tests/integration/devhost/mcu_update_http_uart_fault_spec.lua
--
-- Go MCU devhost PTY fault/chaos matrix.  This deliberately runs through the
-- public HTTP update path and the real Lua service stack, then pushes byte-level
-- PTY faults through the UART middleware.  It skips cleanly when the Go devhost
-- binary cannot be supplied or built.

local base = require 'integration.devhost.mcu_update_http_uart_spec'
local H = assert(base.__helpers, 'mcu_update_http_uart_spec helpers unavailable')

local T = {}

local function log(msg)
    H.log('[fault-matrix] ' .. tostring(msg))
end

local function run_case(case)
    log('case start: ' .. tostring(case.name))
    local result = H.run_go_devhost_pty_cycle({
        label = case.name,
        blob_bytes = case.blob_bytes,
        uart = case.uart,
        reboot_uart = case.reboot_uart,
        timeout_s = case.timeout_s,
        stage_timeout_s = case.stage_timeout_s,
    })
    if result and result.skipped then
        log('case skipped: ' .. tostring(result.reason))
        return result
    end
    assert(result and result.ok, 'case did not return ok: ' .. tostring(case.name))
    if type(case.assert_stats) == 'function' then
        case.assert_stats(result.first_uart_stats or {}, result.second_uart_stats or {})
    end
    log('case ok: ' .. tostring(case.name))
    return result
end

local function assert_at_least(v, n, what)
    if not ((tonumber(v) or 0) >= n) then
        error(('expected %s >= %d, got %s'):format(what, n, tostring(v)), 0)
    end
end

local function cases()
    return {
        {
            name = 'standalone-bad-json-both-directions',
            blob_bytes = 24 * 1024,
            uart = {
                malformed_line_count = 1,
                faults = {
                    cm5_to_mcu = { malformed_line_count = 2, malformed_line_first_at = 1536, malformed_line_every_bytes = 8192 },
                    mcu_to_cm5 = { malformed_line_count = 2, malformed_line_first_at = 512, malformed_line_every_bytes = 8192 },
                },
            },
            assert_stats = function (st)
                assert_at_least(st.malformed_lines, 2, 'malformed lines')
            end,
        },
        {
            name = 'single-byte-loss-in-cm5-bulk-frame',
            blob_bytes = 32 * 1024,
            uart = {
                malformed_line_count = 0,
                faults = {
                    cm5_to_mcu = { disable_malformed = true, drop_byte_after_bytes = 4096 },
                    mcu_to_cm5 = { disable_malformed = true },
                },
            },
            assert_stats = function (st)
                assert_at_least(st.dropped_bytes, 1, 'dropped bytes')
            end,
        },
        {
            name = 'single-byte-loss-in-mcu-control-frame',
            blob_bytes = 32 * 1024,
            uart = {
                malformed_line_count = 0,
                faults = {
                    cm5_to_mcu = { disable_malformed = true },
                    mcu_to_cm5 = { disable_malformed = true, drop_byte_after_bytes = 3072 },
                },
            },
            assert_stats = function (st)
                assert_at_least(st.dropped_bytes, 1, 'dropped bytes')
            end,
        },
        {
            name = 'long-pauses-both-directions',
            blob_bytes = 48 * 1024,
            uart = {
                malformed_line_count = 0,
                faults = {
                    cm5_to_mcu = { disable_malformed = true, pause_once_after_bytes = 4096, pause_s = 0.65 },
                    mcu_to_cm5 = { disable_malformed = true, pause_once_after_bytes = 2048, pause_s = 0.65 },
                },
            },
            assert_stats = function (st)
                assert_at_least(st.fault_pauses, 2, 'fault pauses')
            end,
        },
        {
            name = 'combined-bad-json-byte-loss-and-pauses',
            blob_bytes = 64 * 1024,
            uart = {
                malformed_line_count = 1,
                faults = {
                    cm5_to_mcu = {
                        malformed_line_count = 1,
                        malformed_line_first_at = 1536,
                        drop_byte_after_bytes = 8192,
                        pause_once_after_bytes = 16384,
                        pause_s = 0.55,
                    },
                    mcu_to_cm5 = {
                        malformed_line_count = 1,
                        malformed_line_first_at = 1024,
                        drop_byte_after_bytes = 12288,
                        pause_once_after_bytes = 24576,
                        pause_s = 0.55,
                    },
                },
            },
            assert_stats = function (st)
                assert_at_least(st.malformed_lines, 1, 'malformed lines')
                assert_at_least(st.dropped_bytes, 1, 'dropped bytes')
                assert_at_least(st.fault_pauses, 2, 'fault pauses')
            end,
        },
    }
end

function T.go_devhost_pty_fiendish_transport_recovery_matrix()
    for _, case in ipairs(cases()) do
        local result = run_case(case)
        if result and result.skipped then return end
    end
end

function T.go_devhost_pty_destructive_newline_loss_documents_stop_wait_failure()
    local enabled = os.getenv('MCU_HTTP_UART_DESTRUCTIVE_FAULTS')
    if enabled ~= '1' and enabled ~= 'true' then
        log('skipping destructive newline-loss case; set MCU_HTTP_UART_DESTRUCTIVE_FAULTS=1')
        return
    end
    run_case({
        name = 'destructive-newline-loss-mcu-to-cm5',
        blob_bytes = 32 * 1024,
        stage_timeout_s = 25.0,
        timeout_s = 80.0,
        uart = {
            malformed_line_count = 0,
            faults = {
                cm5_to_mcu = { disable_malformed = true },
                mcu_to_cm5 = { disable_malformed = true, drop_next_newline_after_bytes = 3072 },
            },
        },
        assert_stats = function (st)
            assert_at_least(st.dropped_newlines, 1, 'dropped newlines')
        end,
    })
end

return T
