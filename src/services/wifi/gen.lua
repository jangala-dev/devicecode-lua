local digest = require "openssl.digest"
local string = require "string"

function string.tohex(str)
    return (str:gsub('.', function (c)
        return string.format('%02X', string.byte(c))
    end))
end

if digest.digest == nil then
    function digest.digest(algo, str)
        return digest.new(algo):final(str):tohex():lower()
    end
end

local USER_SALT = "$USER_SALT"
local USER_ID_LEN = 6

local function userid(mac)
    local hash = digest.digest("sha256", USER_SALT..mac)
    return string.sub(hash, 1, USER_ID_LEN)
end

local function gen_session_id()
    local random = math.random
    local template = 'xxxxxxxx_xxxx_4xxx_yxxx_xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function (char)
        local value = (char == 'x') and random(0, 0xf) or random(8, 0xb)
        return string.format('%x', value)
    end)
end

return {
    userid = userid,
    gen_session_id = gen_session_id,
}
