local log = require 'services.log'
local service = require 'service'
local new_msg = require 'bus'.new_msg
local op = require 'fibers.op'
local context = require 'fibers.context'
local unpack = table.unpack or unpack

local ota_update = {
    name = 'ota_update'
}
ota_update.__index = ota_update

local IMAGES_URL = "https://jangala-modem-firmware.s3.eu-west-1.amazonaws.com"
local TARGET_FIRMWARE = "EG25GGBR07A08M2G_A0.204.A0.204"
local TARGET_REVISION = "eg25g"

local function log_error(ctx, message)
    log.error(string.format(
        "%s - %s: %s",
        ctx:value("service_name"),
        ctx:value("fiber_name"),
        message
    ))
end

local function make_capability_topic(capability)
    return { 'hal', 'capability', capability, '+' }
end

local function make_info_topic(capability, index, info_topic)
    return { 'hal', 'capability', capability, index, 'info', unpack(info_topic) }
end

local function make_control_topic(capability, index, control)
    return { 'hal', 'capability', capability, index, 'control', control }
end

local function starts_with(main, sub)
    if main == nil or sub == nil then return false end
    main, sub = main:lower(), sub:lower()
    -- Use string.sub to get the prefix of mainString that is equal in length to startString
    return string.sub(main, 1, string.len(sub)) == sub
end

local function is_modem_match(ctx, index)
    local revision_sub = ota_update.conn:subscribe(
        make_info_topic('modem', index, { 'modem', 'generic', 'revision' })
    )
    local revision_msg, rev_sub_err = revision_sub:next_msg_with_context(ctx)
    revision_sub:unsubscribe()
    if rev_sub_err then
        return false, string.format(
            "Error receiving modem revision message: %s",
            rev_sub_err
        )
    end

    local revision = revision_msg.payload
    if starts_with(revision, TARGET_REVISION) then
        return true, nil
    end
    return false, nil
end

local function update(ctx)
    local modem_cap_sub = ota_update.conn:subscribe(make_capability_topic('modem'))

    local cap_index
    while not ctx:err() do
        local modem_cap_msg, sub_err = modem_cap_sub:next_msg_with_context(context.with_timeout(ctx, 30))
        if sub_err then
            log_error(ctx, string.format(
                "Error receiving modem capability message: %s",
                sub_err
            ))
            break
        end
        local index = modem_cap_msg.payload.index

        local is_match, match_err = is_modem_match(ctx, index)
        if match_err then
            log_error(ctx, match_err)
            break
        end
        if is_match then
            cap_index = index
            break
        end
    end

    modem_cap_sub:unsubscribe()

    if not cap_index then
        log_error(ctx, "No matching modem capability found")
        return
    end

    local firmware_sub = ota_update.conn:subscribe(
        make_info_topic('modem', cap_index, { 'modem', 'firmware' })
    )
    local firmware_msg, fw_sub_err = firmware_sub:next_msg_with_context(ctx)
    firmware_sub:unsubscribe()

    if fw_sub_err then
        log_error(ctx, string.format(
            "Error receiving modem firmware message: %s",
            fw_sub_err
        ))
        return
    end

    local current_firmware = firmware_msg.payload

    local update_file = string.format(
        "%s/%s-%s.zip",
        IMAGES_URL,
        current_firmware,
        TARGET_FIRMWARE
    )

    log.info("OTA Update - updating with file " .. update_file)

    local ota_update_sub = ota_update.conn:request(new_msg(
        make_control_topic('modem', cap_index, 'ota_update'),
        { ctx, update_file }
    ))

    local ota_update_progress_sub = ota_update.conn:subscribe(
        make_info_topic('modem', cap_index, { 'update', 'progress' })
    )
    local ota_exit_sub = ota_update.conn:subscribe(
        make_info_topic('modem', cap_index, { 'update', 'exit_code' })
    )

    while not ctx:err() do
        local exit, err = op.choice(
            ota_update_sub:next_msg_op():wrap(function (msg)
                if msg.payload == nil then return nil, nil end
                local res = msg.payload.result
                local err = msg.payload.err
                return res, err
            end),
            ota_update_progress_sub:next_msg_op():wrap(function (msg)
                if msg.payload == nil then return nil, nil end
                local progress = msg.payload
                log.info(string.format(
                    "OTA Update Progress: %d%%",
                    progress
                ))
                return nil, nil
            end),
            ota_exit_sub:next_msg_op():wrap(function (msg)
                if msg.payload == nil then return nil, nil end
                local code = msg.payload
                return code, code ~= 0 and code or nil;
            end)
        ):perform()
        if err then
            log_error(ctx, string.format(
                "Error during OTA update: %s",
                err
            ))
            break
        end
        if exit then
            log.info("OTA Update completed successfully with code " .. tostring(exit))
            break
        end
    end

    ota_update_sub:unsubscribe()
    ota_update_progress_sub:unsubscribe()
    ota_exit_sub:unsubscribe()
end


function ota_update:start(ctx, conn)
    self.ctx = ctx
    self.conn = conn
    -- Placeholder for future implementation

    service.spawn_fiber('OTA Update', conn, ctx, update)
end

return ota_update
