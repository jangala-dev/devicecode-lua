local WSConnection = {
    buffer={},
}
WSConnection.__index = WSConnection

function WSConnection.new_WSConnection(ws)
    return setmetatable({ws = ws}, WSConnection)
end

function WSConnection:readMsg()
    local txt, opcode = self.ws:receive()
    local result = nil

    -- if txt == nil then break end
    if txt ~= nil then
        if string.byte(txt,1,1) == 2 then
            self.buffer = {}
        elseif string.byte(txt,1,1) == 3 then
            result_string = table.concat(self.buffer)
            local result_decoded, _, err = json.decode(result_string)
            if err then
                print("Error decoding message: ", err)
            else
                result = result_decoded
            end

            self.buffer = {}
        else
            self.buffer[#self.buffer+1]=string.sub(txt,1,1)
        end
    end

    return result ~= nil, result
end

function WSConnection:close()
    self.ws:close()
end

return WSConnection