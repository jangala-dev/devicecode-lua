local digest = require "openssl.digest"

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
