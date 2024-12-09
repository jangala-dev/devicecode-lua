local queue = require "fibers.queue"
local fiber = require "fibers.fiber"
local sleep = require "fibers.sleep"
local file = require "fibers.stream.file"
local json = require "dkjson"

-- No modems were found
-- (+) /org/freedesktop/ModemManager1/Modem/13 [QUALCOMM INCORPORATED] QUECTEL Mobile Broadband Module
-- (-) /org/freedesktop/ModemManager1/Modem/13 [QUALCOMM INCORPORATED] QUECTEL Mobile Broadband Module
-- pattern = (<state_change>) <device_address> [<manufacturer>] <model>

local ModemCard = {}
ModemCard.__index = ModemCard

local ModemEvents = {}
ModemEvents.__index = ModemEvents

local EventFeed = {}
EventFeed.__index = EventFeed

local function new_event_feed(event_q)
    return setmetatable({event_q = event_q}, EventFeed)
end

function EventFeed:lines()
    local iterator_func = function ()
        if self.buf ~= nil then
            local val = self.buf
            self.buf = nil
            return val
        end
        local event = self.event_q:get_op():perform_alt(function () return nil end)
        if event == nil then return event end
        if event.address == nil then return event.message end
        local line = string.format("(%s) %s [%s] %s",
            event.connected and '+' or '-',
            event.address,
            event.manufacturer,
            event.model
        )
        return line
    end

    return iterator_func
end

function EventFeed:close()
end

local function new_events()
    return setmetatable({event_q = queue.new(), modems = {}, buf = {}}, ModemEvents)
end

function ModemEvents:stdout_pipe()
    return new_event_feed(self.event_q)
end

function ModemEvents:start()
    local modemcards_file, err = file.open("./modemcards.json", "r")
    local modemcards
    if err then
        return err
    else
        modemcards = json.decode(modemcards_file:read_all_chars())
    end

    -- start a fiber that adds things to the event queue
    fiber.spawn(function ()
        self.event_q:put({
            message = 'No modems detected'
        })
        sleep.sleep(1)
        local card = ModemCard.new(modemcards.modems[0])
        self.modems[card.address] = card
        self.event_q:put({
            connected = true,
            address = card["dbus-path"],
            manufacturer = card.manufacturer,
            model = card.model
        })
        sleep.sleep(3)
        card = ModemCard.new(modemcards.modems[1])
        self.modems[card.address] = card
        self.event_q:put({
            connected = true,
            address = card["dbus-path"],
            manufacturer = card.manufacturer,
            model = card.model
        })
        sleep.sleep(3)
        local address = modemcards.modems[0]['dbus-path']
        card = self.modems[address]
        self.event_q:put({
            connected = false,
            address = card["dbus-path"],
            manufacturer = card.generic.manufacturer,
            model = card.generic.model
        })
        self.modems[address] = nil
    end)
end

function ModemEvents:wait()
    self.buf = self.event_q:get()
end

return {new_events = new_events}