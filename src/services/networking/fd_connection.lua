local json = require 'dkjson'
local log = require 'log'
local file = require 'fibers.stream.file'
local sleep = require 'fibers.sleep'

local FDConnection = {
    buffer={},
    total_read=0
}

FDConnection.__index = FDConnection

function FDConnection.new_FDConnection(path_read, path_send)
    local read_file = nil
    if path_read ~= nil then
        read_file = file.open(path_read, 'r')
        if read_file == nil then
            read_file = file.open(path_read, 'w')
            if read_file == nil then
                print("Error opening file "..path_read)
                return
            end

            read_file:write("")
            read_file:close()
            read_file = file.open(path_read, 'r')
        end

        if read_file == nil then
            print("Error opening file "..path_read)
            return
        end
    end

    local send_file = nil
    if path_send ~= nil then
        send_file = file.open(path_send, 'a')
        if send_file == nil then
            print("Error opening file "..path_send)

            if read_file ~= nil then
                read_file:close()
            end

            return
        end
    end

    if send_file == nil and read_file == nil then
        print("No valid read or send file provided")
        return
    end

    return setmetatable({read_file = read_file, send_file = send_file, fd = fd, buf=buf}, FDConnection)
end

function FDConnection:readMsg()
    local txt = self.read_file:read_some_chars()
    local result = nil
    if txt ~= nil then
        print("Received Message", txt)
        local msg, _, err = json.decode(txt)
        if err then
            print("Error decoding message: ", err)
        else
            result = msg
        end
    end

    return result ~= nil, result
end

function FDConnection:sendMsg(msg)
    local msg_string = string.char(2)..json.encode(msg)..string.char(3)
    print("Sending message: ", msg_string)
    self.send_file:write(msg_string)
    self.send_file:flush()
end

return FDConnection