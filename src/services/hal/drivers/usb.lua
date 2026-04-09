-- services/hal/drivers/usb.lua
--
-- USB bus HAL driver.
-- Manages the USB 3.0 bus enable/disable state via sysfs power control.
-- Exposes a 'usb' capability with 'enable' and 'disable' RPC offerings.
-- Current state is probed at driver creation and published as state/bus
-- on start().

local fibers  = require "fibers"
local op      = require "fibers.op"
local sleep   = require "fibers.sleep"
local file    = require "fibers.io.file"
local exec    = require "fibers.io.exec"
local channel = require "fibers.channel"

local hal_types = require "services.hal.types.core"
local cap_types = require "services.hal.types.capabilities"

local perform = fibers.perform

local CONTROL_Q_LEN = 8

local function dlog(logger, level, payload)
    if logger and logger[level] then
        logger[level](logger, payload)
    end
end

-- Sysfs base path for USB hubs on bigbox-ss hardware (BCM2711 / VL805).
local USB_HUB_PREFIX = "/sys/devices/platform/scb/fd500000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0/usb"

-- Sysfs subpaths for each hub port, relative to USB_HUB_PREFIX .. hub_number.
-- Hub 1 = USB 2.0 host; Hub 2 = USB 3.0 host.
local USB_PORT_SUBPATHS = {
    [1] = { [1] = "1-1/1-1.1", [2] = "1-1/1-1.2", [3] = "1-1/1-1.3", [4] = "1-1/1-1.4" },
    [2] = { [1] = "2-1",       [2] = "2-2" },
}

-- Minimum VL805 firmware timestamp for hub power control support (2019-09-10).
local VL805_SUPPORTED_FROM = os.time({ year = 2019, month = 9, day = 10, hour = 0, min = 0, sec = 0 })

---@class UsbDriver
---@field bus_id string       capability id, e.g. "usb3"
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel?
---@field enabled boolean     current logical state
---@field logger Logger?
local UsbDriver = {}
UsbDriver.__index = UsbDriver

---- helpers ----

--- Probe USB3 state from hub 2's authorized_default sysfs node.
--- Returns true (enabled) as a safe default when unavailable.
---@return boolean
local function probe_usb3_state()
    local path = USB_HUB_PREFIX .. '2/authorized_default'
    local f, _ = file.open(path, 'r')
    if not f then return true end
    local raw, _ = f:read_all()
    f:close()
    if raw then
        local val = tonumber(raw:match("%d+"))
        return val ~= nil and val ~= 0
    end
    return true
end

--- Return true if a USB device is present at the given hub/port sysfs path.
---@param hub integer
---@param port integer
---@return boolean present
---@return string? error
local function is_device_on_hub_port(hub, port)
    local subpaths = USB_PORT_SUBPATHS[hub]
    if not subpaths then return false, "invalid hub" end
    if not subpaths[port] then return false, "invalid port" end
    local path = USB_HUB_PREFIX .. hub .. '/' .. subpaths[port]
    local cmd = exec.command('test', '-e', path)
    local _, _, code = perform(cmd:run_op())
    return code == 0, nil
end

--- Write an integer to a sysfs path via /bin/sh.
---@param path string
---@param value integer
---@return string? error
local function exec_write_to_file(path, value)
    local cmd = exec.command('/bin/sh', '-c', ('echo %d > %s'):format(value, path))
    local _, _, code = perform(cmd:run_op())
    if code ~= 0 then
        return ("write to %s failed (exit %d)"):format(path, code or -1)
    end
    return nil
end

---@param enabled boolean
---@param hub integer
---@return string? error
local function set_usb_hub_auth_default(enabled, hub)
    return exec_write_to_file(USB_HUB_PREFIX .. hub .. '/authorized_default', enabled and 1 or 0)
end

---@param enabled boolean
---@param hub integer
---@param port integer
---@return string? error
local function set_usb_port_auth(enabled, hub, port)
    return exec_write_to_file(
        USB_HUB_PREFIX .. hub .. '/' .. USB_PORT_SUBPATHS[hub][port] .. '/authorized',
        enabled and 1 or 0)
end

--- Deauthorize all occupied USB3 (hub 2) ports.
---@return boolean hub_was_used
---@return string? error
local function clear_usb3_hub()
    local hub_used = false
    for i = 1, #USB_PORT_SUBPATHS[2] do
        local present, err = is_device_on_hub_port(2, i)
        if err then return false, "error checking port " .. i .. ": " .. err end
        if present then
            hub_used = true
            err = set_usb_port_auth(false, 2, i)
            if err then return true, "error deauthorising port " .. i .. ": " .. err end
        end
    end
    return hub_used, nil
end

--- Re-authorize all occupied USB3 (hub 2) ports.
---@return boolean hub_was_used
---@return string? error
local function repopulate_usb3_hub()
    local hub_used = false
    for i = 1, #USB_PORT_SUBPATHS[2] do
        local present, err = is_device_on_hub_port(2, i)
        if err then return false, "error checking port " .. i .. ": " .. err end
        if present then
            hub_used = true
            err = set_usb_port_auth(true, 2, i)
            if err then return true, "error reauthorising port " .. i .. ": " .. err end
        end
    end
    return hub_used, nil
end

--- Control USB hub power via uhubctl.
---@param enabled boolean
---@param hub integer
---@return string? error
local function set_usb_hub_power(enabled, hub)
    local cmd = exec.command('uhubctl', '-e', '-l', tostring(hub), '-a', tostring(enabled and 1 or 0))
    local _, _, code = perform(cmd:run_op())
    if code ~= 0 then
        return ("uhubctl hub %d power %s failed (exit %d)"):format(
            hub, enabled and 'on' or 'off', code or -1)
    end
    return nil
end

--- Read the VL805 hub controller firmware timestamp via vcgencmd.
---@return integer? timestamp
---@return string? error
local function get_vl805_timestamp()
    local cmd = exec.command('vcgencmd', 'bootloader_version')
    local out, _, code = perform(cmd:output_op())
    if code ~= 0 or not out then
        return nil, "vcgencmd bootloader_version failed"
    end
    local timestamp = out:match("timestamp%s+(%d+)")
    if not timestamp then
        return nil, "timestamp not found in bootloader version output"
    end
    return tonumber(timestamp), nil
end

---@param enabled boolean
---@param logger Logger?
local function emit_state(emit_ch, bus_id, enabled, logger)
    if not emit_ch then return end
    local payload, err = hal_types.new.Emit('usb', bus_id, 'state', 'bus', { enabled = enabled })
    if not payload then
        dlog(logger, 'debug', { what = 'state_emit_failed', err = tostring(err) })
        return
    end
    emit_ch:put(payload)
end

---- capability verbs ----

---@param _opts table?
---@return boolean ok
---@return any value_or_err
function UsbDriver:enable(_opts)
    if self.enabled then
        return true, nil
    end

    local auth_err = set_usb_hub_auth_default(true, 2)
    if auth_err then
        dlog(self.logger, 'warn', { what = 'restore_authorized_default_failed', err = tostring(auth_err) })
    end

    local power_err = set_usb_hub_power(true, 2)
    if power_err then
        return false, power_err
    end

    self.enabled = true
    emit_state(self.cap_emit_ch, self.bus_id, true)
    return true, nil
end

---@param _opts table?
---@return boolean ok
---@return any value_or_err
function UsbDriver:disable(_opts)
    if not self.enabled then
        return true, nil
    end

    -- Verify VL805 firmware supports hub power control.
    local vl805_ts, ts_err = get_vl805_timestamp()
    if ts_err then
        return false, "could not verify VL805 firmware: " .. ts_err
    end
    if vl805_ts < VL805_SUPPORTED_FROM then
        return false, ("VL805 firmware too old (timestamp %d, need >= %d)"):format(
            vl805_ts, VL805_SUPPORTED_FROM)
    end

    -- Deauthorize each connected USB3 port so devices fall back to USB2.
    local hub_used, clear_err = clear_usb3_hub()
    if clear_err then
        dlog(self.logger, 'error', { what = 'clear_usb3_hub_failed', err = tostring(clear_err) })
        repopulate_usb3_hub()
        set_usb_hub_auth_default(true, 2)
        return false, clear_err
    end
    if not hub_used then
        -- No active USB3 connections; still prevent future connections.
        dlog(self.logger, 'info', { what = 'no_usb3_devices_connected' })
        set_usb_hub_auth_default(false, 2)
        self.enabled = false
        emit_state(self.cap_emit_ch, self.bus_id, false, self.logger)
        return true, nil
    end

    -- Prevent future USB3 connections.
    local auth_err = set_usb_hub_auth_default(false, 2)
    if auth_err then
        dlog(self.logger, 'warn', { what = 'set_authorized_default_failed', err = tostring(auth_err) })
    end

    -- Power down USB3 hub to force devices onto USB2.
    local power_err = set_usb_hub_power(false, 2)
    if power_err then
        dlog(self.logger, 'error', { what = 'power_down_usb3_hub_failed', err = tostring(power_err) })
        set_usb_hub_power(true, 2)
        repopulate_usb3_hub()
        set_usb_hub_auth_default(true, 2)
        return false, power_err
    end

    -- Wait up to 10 seconds for USB3 devices to re-enumerate on the USB2 hub.
    local awaiting_1 = is_device_on_hub_port(2, 1)
    local awaiting_2 = is_device_on_hub_port(2, 2)
    local migrated = false
    for _ = 1, 10 do
        local p1_ok = not (awaiting_1 and not is_device_on_hub_port(1, 1))
        local p2_ok = not (awaiting_2 and not is_device_on_hub_port(1, 2))
        if p1_ok and p2_ok then migrated = true; break end
        perform(sleep.sleep_op(1))
    end
    if not migrated then
        dlog(self.logger, 'warn', { what = 'usb3_migration_incomplete' })
    end

    self.enabled = false
    emit_state(self.cap_emit_ch, self.bus_id, false, self.logger)
    return true, nil
end

---- control manager ----

function UsbDriver:control_manager()
    fibers.current_scope():finally(function()
        dlog(self.logger, 'debug', { what = 'control_manager_exiting' })
    end)

    while true do
        local request, req_err = self.control_ch:get()
        if not request then
            dlog(self.logger, 'debug', { what = 'control_ch_closed', err = tostring(req_err) })
            break
        end

        local fn = self[request.verb]
        local ok, value_or_err
        if type(fn) ~= 'function' then
            ok, value_or_err = false, "unsupported verb: " .. tostring(request.verb)
        else
            local st, _, r1, r2 = fibers.run_scope(function()
                return fn(self, request.opts)
            end)
            if st ~= 'ok' then
                ok, value_or_err = false, "internal error: " .. tostring(r1)
            else
                ok, value_or_err = r1, r2
            end
        end

        local reply = hal_types.new.Reply(ok, value_or_err)
        if reply then
            request.reply_ch:put(reply)
        end
    end
end

---- public interface ----

---@return string error
function UsbDriver:init()
    if self.initialised then
        return "already initialised"
    end
    self.initialised = true
    return ""
end

---@param emit_ch Channel
---@return Capability[]?
---@return string error
function UsbDriver:capabilities(emit_ch)
    if not self.initialised then
        return nil, "usb driver not initialised"
    end
    self.cap_emit_ch = emit_ch
    local cap, err = cap_types.new.UsbCapability(self.bus_id, self.control_ch)
    if not cap then
        return {}, err
    end
    return { cap }, ""
end

---@return boolean ok
---@return string error
function UsbDriver:start()
    if not self.initialised then
        return false, "usb driver not initialised"
    end
    if self.cap_emit_ch then
        -- Publish initial bus state.
        emit_state(self.cap_emit_ch, self.bus_id, self.enabled, self.logger)

        -- Publish meta.
        local meta_payload, meta_err = hal_types.new.Emit('usb', self.bus_id, 'meta', 'info', {
            provider = 'hal',
            version  = 1,
            bus_id   = self.bus_id,
        })
        if meta_payload then
            self.cap_emit_ch:put(meta_payload)
        else
            dlog(self.logger, 'debug', { what = 'meta_emit_failed', err = tostring(meta_err) })
        end
    end

    local ok, spawn_err = self.scope:spawn(function()
        self:control_manager()
    end)
    if not ok then
        return false, "failed to spawn control_manager: " .. tostring(spawn_err)
    end
    return true, ""
end

---@param timeout number?
---@return boolean ok
---@return string error
function UsbDriver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel(('usb driver [%s] stopped'):format(self.bus_id))
    local source = perform(op.named_choice {
        join    = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })
    if source == 'timeout' then
        return false, ("usb driver [%s] stop timeout"):format(self.bus_id)
    end
    return true, ""
end

---@param bus_id string  capability id, e.g. "usb3"
---@param logger Logger?
---@return UsbDriver?
---@return string error
local function new(bus_id, logger)
    bus_id = bus_id or 'usb3'

    local scope, err = fibers.current_scope():child()
    if not scope then
        return nil, "failed to create child scope: " .. tostring(err)
    end

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            dlog(logger, 'error', { what = 'scope_failed', err = tostring(primary), status = st })
        end
        dlog(logger, 'debug', { what = 'stopped' })
    end)

    local enabled = probe_usb3_state()

    return setmetatable({
        bus_id      = bus_id,
        scope       = scope,
        control_ch  = channel.new(CONTROL_Q_LEN),
        cap_emit_ch = nil,
        enabled     = enabled,
        logger      = logger,
        initialised = false,
    }, UsbDriver), ""
end

return { new = new }
