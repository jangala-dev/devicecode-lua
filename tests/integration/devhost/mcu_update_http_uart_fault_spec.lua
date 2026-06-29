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

local function env_bool(name, default_value)
    local raw = os.getenv(name)
    if raw == nil or raw == '' then return default_value end
    raw = tostring(raw):lower():match('^%s*(.-)%s*$')
    if raw == '1' or raw == 'true' or raw == 'yes' or raw == 'on' then return true end
    if raw == '0' or raw == 'false' or raw == 'no' or raw == 'off' then return false end
    error(('%s must be boolean-like'):format(name), 0)
end

local function env_size_bytes(name, default_value)
    local raw = os.getenv(name)
    if raw == nil or raw == '' then return default_value end
    raw = tostring(raw):match('^%s*(.-)%s*$')
    local number, suffix = raw:match('^(%d+)%s*([kKmMgG]?[iI]?[bB]?)$')
    if number == nil then error(('invalid %s=%q'):format(name, raw), 0) end
    local n = tonumber(number)
    suffix = suffix:lower()
    if suffix == 'k' or suffix == 'kb' or suffix == 'kib' then n = n * 1024
    elseif suffix == 'm' or suffix == 'mb' or suffix == 'mib' then n = n * 1024 * 1024
    elseif suffix == 'g' or suffix == 'gb' or suffix == 'gib' then n = n * 1024 * 1024 * 1024
    elseif suffix ~= '' and suffix ~= 'b' then error(('invalid %s=%q'):format(name, raw), 0) end
    return n
end

local FULL_FAULT_MATRIX = env_bool('MCU_HTTP_UART_FULL_FAULT_MATRIX', false)
local FAULT_BLOB_BYTES = env_size_bytes('MCU_HTTP_UART_FAULT_BLOB_BYTES', 8 * 1024)


local function cases()
    return {
        {
            name = 'standalone-bad-json-both-directions',
            blob_bytes = FAULT_BLOB_BYTES,
            uart = {
                malformed_line_count = 1,
                faults = {
                    cm5_to_mcu = { malformed_line_count = 2, malformed_line_first_at = 1536, malformed_line_every_bytes = 4096 },
                    mcu_to_cm5 = { malformed_line_count = 2, malformed_line_first_at = 512, malformed_line_every_bytes = 4096 },
                },
            },
            assert_stats = function (st)
                assert_at_least(st.malformed_lines, 2, 'malformed lines')
            end,
        },
        {
            name = 'single-byte-loss-in-cm5-bulk-frame',
            blob_bytes = FAULT_BLOB_BYTES,
            uart = {
                malformed_line_count = 0,
                faults = {
                    cm5_to_mcu = { disable_malformed = true, drop_byte_after_bytes = 3072 },
                    mcu_to_cm5 = { disable_malformed = true },
                },
            },
            assert_stats = function (st)
                assert_at_least(st.dropped_bytes, 1, 'dropped bytes')
            end,
        },
        {
            name = 'single-byte-loss-in-mcu-control-frame',
            blob_bytes = FAULT_BLOB_BYTES,
            uart = {
                malformed_line_count = 0,
                faults = {
                    cm5_to_mcu = { disable_malformed = true },
                    mcu_to_cm5 = { disable_malformed = true, drop_byte_in_frame_type = 'xfer_need' },
                },
            },
            assert_stats = function (st)
                assert_at_least(st.dropped_bytes, 1, 'dropped bytes')
            end,
        },
        {
            name = 'long-pauses-both-directions',
            blob_bytes = FAULT_BLOB_BYTES,
            uart = {
                malformed_line_count = 0,
                faults = {
                    cm5_to_mcu = { disable_malformed = true, pause_once_after_bytes = 4096, pause_s = 0.20 },
                    mcu_to_cm5 = { disable_malformed = true, pause_once_after_bytes = 2048, pause_s = 0.20 },
                },
            },
            assert_stats = function (st)
                assert_at_least(st.fault_pauses, 2, 'fault pauses')
            end,
        },
        {
            name = 'combined-bad-json-byte-loss-and-pauses',
            blob_bytes = FAULT_BLOB_BYTES,
            uart = {
                malformed_line_count = 1,
                faults = {
                    cm5_to_mcu = {
                        malformed_line_count = 1,
                        malformed_line_first_at = 1536,
                        drop_byte_after_bytes = 8192,
                        pause_once_after_bytes = 4096,
                        pause_s = 0.20,
                    },
                    mcu_to_cm5 = {
                        malformed_line_count = 1,
                        malformed_line_first_at = 1024,
                        drop_byte_in_frame_type = 'xfer_need',
                        pause_once_after_bytes = 1024,
                        pause_s = 0.20,
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
    for i, case in ipairs(cases()) do
        if FULL_FAULT_MATRIX or i <= 3 then
            local result = run_case(case)
            if result and result.skipped then return end
        else
            log('case skipped in normal CI: ' .. tostring(case.name) .. ' (set MCU_HTTP_UART_FULL_FAULT_MATRIX=1)')
        end
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
        blob_bytes = FAULT_BLOB_BYTES,
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
