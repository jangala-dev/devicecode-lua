local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local json = require 'dkjson'

local dummy_service = {}
dummy_service.__index = dummy_service

local function rn(a, b)
    math.randomseed(os.time())
    return math.random(a, b)
end

local function rp()
    local states = {
        "connected",
        "disconnected"
    }
    local index = rn(1, #states)
    return states[index]
end

local function rb()
    local states = {
        "missing",
        "connected",
        "charged"
    }
    local index = rn(1, #states)
    return states[index]
end


local function get_dummy_data_static()
    return {
        { type = "publish", topic = "t.net.wan.is_online",   payload = { n = "is_online", vb = false } },
        { type = "publish", topic = "t.system.fw_id",        payload = { n = "fw_id", vs = "openwrt" } },
        { type = "publish", topic = "t.system.hw_id",        payload = { n = "hw_id", vs = "getbox" } },
        { type = "publish", topic = "t.system.serial",       payload = { n = "serial", vs = "GBAAEBBBBBWEEE" } },
        { type = "publish", topic = "t.net.wwan.is_online",  payload = { n = "is_online", vb = true } },
        { type = "publish", topic = "t.net.wwanb.is_online", payload = { n = "is_online", vb = false } },
        { type = "publish", topic = "t.modem.1.access_tech", payload = { n = "access_tech", vs = "lte" } },
        { type = "publish", topic = "t.modem.1.access_fam",  payload = { n = "access_fam", vs = "4g" } },
        { type = "publish", topic = "t.modem.1.operator",    payload = { n = "operator", vs = "ee" } },
        { type = "publish", topic = "t.modem.1.sim",         payload = { n = "sim", vs = "inserted" } },
        { type = "publish", topic = "t.modem.1.state",       payload = { n = "state", vs = "connected" } },
        { type = "publish", topic = "t.modem.1.signal_type", payload = { n = "signal_type", vs = "good" } },
        { type = "publish", topic = "t.modem.1.band",        payload = { n = "band", vs = "b7" } },
        { type = "publish", topic = "t.modem.1.bars",        payload = { n = "bars", vs = "3" } },
        { type = "publish", topic = "t.modem.1.wwan_type",   payload = { n = "wwan_type", vs = "wwan" } },
        { type = "publish", topic = "t.modem.1.imei",        payload = { n = "imei", vs = "350123451234560" } },
        { type = "publish", topic = "t.modem.2.sim",         payload = { n = "sim", vs = "no sim" } },
        { type = "publish", topic = "t.modem.2.wwan_type",   payload = { n = "wwan_type", vs = "wwanb" } },
    }
end

local wwan_online_for = 0

local function get_dummy_dynamic()
    wwan_online_for = wwan_online_for + rn(5, 20)

    return {
        {type = "publish", topic = "t.mcu.temp", payload = {n = "temp", v = rn(25, 50) }},
        {type = "publish", topic = "t.power", payload = {n = "power", vs = rp() }},
        {type = "publish", topic = "t.battery", payload = {n = "battery", vs = rb() }},
        {type = "publish", topic = "t.system.cpu_util", payload = {n = "cpu_util", v = rn(10, 200) }},
        {type = "publish", topic = "t.system.mem_util", payload = {n = "mem_util", v = rn(5, 100) }},
        {type = "publish", topic = "t.system.temp", payload = {n = "temp", v = rn(25, 50) }},
        { type = "publish", topic = "t.net.wwan.curr_uptime",  payload = { n = "curr_uptime", v = wwan_online_for } },
        { type = "publish", topic = "t.net.wwan.total_uptime", payload = { n = "total_uptime", v = wwan_online_for } },
    }
end

function dummy_service:start(rootctx, bus_connection)
    self.bus_connection = bus_connection

    local function send_message(message)
        self.bus_connection:publish({
            topic = message.topic,
            payload = json.encode(message),
            retained = true
        })
    end

    fiber.spawn(function()
        while true do
            for _, dummy_example in pairs(get_dummy_dynamic()) do
                send_message(dummy_example)
                sleep.sleep(2)
            end
        end
    end)

    fiber.spawn(function()
        -- Populate any missed static data
        while true do
            for _, dummy_example in pairs(get_dummy_data_static()) do
                send_message(dummy_example)
            end
            sleep.sleep(10)
        end
    end)
end

return dummy_service