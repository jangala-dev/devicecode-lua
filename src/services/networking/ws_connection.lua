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
            result = table.concat(self.buffer)
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
