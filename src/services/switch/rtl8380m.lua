local cjson = require "cjson.safe"
local socket = require "cqueues.socket"
local sleep = require "fibers.sleep"
local basexx = require "basexx"
local exec = require "fibers.exec"

local PORT = 80
local EXPONENT_HEX = "10001"
local DEFAULT_TIMEOUT = 10

-- HTTP helpers
local function build_request(method, path, host, headers, body)
    local req = string.format("%s %s HTTP/1.0\r\n", method, path)
    req = req .. string.format("Host: %s\r\n", host)
    req = req .. "Accept: */*\r\nConnection: close\r\n"

    if headers then
        for k, v in pairs(headers) do
            req = req .. string.format("%s: %s\r\n", k, v)
        end
    end

    req = req .. "\r\n"
    if body then
        req = req .. body
    end

    return req
end

local function parse_body(raw)
    local i = raw:find("\r\n\r\n", 1, true)
    if i then return raw:sub(i + 4) end

    i = raw:find("\n\n", 1, true)
    if i then return raw:sub(i + 2) end

    local j = raw:find("{", 1, true)
    if j then return raw:sub(j) end

    return raw
end

local function safe_write_and_flush(s, data)
    -- write may throw; catch it
    local ok, wres, werr = pcall(function() return s:write(data) end)
    if not ok then return nil, wres end   -- wres is the thrown error
    if not wres then return nil, werr end -- write returned nil, err

    local fok, ferr = pcall(function() return s:flush() end)
    if not fok then return nil, ferr end
    return true
end

local function safe_read_all(s)
    local chunks = {}
    while true do
        local ok, buf, err, part = pcall(function() return s:read(4096) end)
        if not ok then return nil, buf end -- buf is thrown error
        if buf and #buf > 0 then
            chunks[#chunks + 1] = buf
        elseif part and #part > 0 then
            chunks[#chunks + 1] = part
        end
        if not buf then
            if err and err ~= "eof" then
                return nil, "read error: " .. tostring(err)
            end
            break
        end
    end
    return table.concat(chunks)
end

local function get_cgi_json(host, cmd, use_dummy)
    local path = "/cgi/get.cgi?cmd=" ..
    cmd .. (use_dummy and ("&dummy=" .. tostring(math.floor(os.time() * 1000))) or "")
    local s, err = socket.connect(host, PORT)
    if not s then return nil, "connect failed: " .. tostring(err) end

    s:settimeout(DEFAULT_TIMEOUT)
    s:setmode("b", "b")

    local req = build_request("GET", path, host, {})
    local ok, werr = safe_write_and_flush(s, req)
    if not ok then
        s:close(); return nil, "write/flush failed: " .. tostring(werr)
    end

    local raw, rerr = safe_read_all(s)
    s:close()
    if not raw then return nil, rerr end

    local body = parse_body(raw)
    local js, derr = cjson.decode(body)
    if not js then return nil, "decode error: " .. tostring(derr) end
    return js
end

local function post_cgi_json(host, path, payload, headers)
    local s, err = socket.connect(host, PORT)
    if not s then return nil, "connect failed: " .. tostring(err) end

    s:settimeout(DEFAULT_TIMEOUT)
    s:setmode("b", "b")

    local req = build_request("POST", path, host, headers, payload)
    local ok, werr = safe_write_and_flush(s, req)
    if not ok then
        s:close(); return nil, "write/flush failed: " .. tostring(werr)
    end

    local raw, rerr = safe_read_all(s)
    s:close()
    if not raw then return nil, rerr end

    local body = parse_body(raw)
    local js, derr = cjson.decode(body)
    if not js then return nil, "decode error: " .. tostring(derr) end
    return js
end

-- Encryption
local function urlencode_b64(s)
    return (s:gsub("[+/=]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function encrypt_password(modulus_hex, password)
    -- Use /tmp to avoid cluttering working directory
    local temp_id = tostring(os.time()) .. math.random(1000)
    local asn1_file = "/tmp/pubkey_" .. temp_id .. ".asn1"
    local der_file = "/tmp/pubkey_" .. temp_id .. ".der"
    local pem_file = "/tmp/pubkey_" .. temp_id .. ".pem"

    -- 1. Build ASN.1 text (in Lua)
    local asn1 = string.format([[
    asn1=SEQUENCE:pubkey
    [pubkey]
    modulus=INTEGER:0x%s
    pubexp=INTEGER:0x%s
  ]], modulus_hex, EXPONENT_HEX)

    -- Write to temp file
    local f = io.open(asn1_file, "w")
    if not f then return nil, "cannot write asn1 file" end
    f:write(asn1)
    f:close()

    -- 2. Generate DER
    local err = exec.command("openssl", "asn1parse", "-genconf", asn1_file, "-out", der_file, "-noout"):run()

    if err then
        exec.command("rm", asn1_file):run()
        return nil, "asn1parse failed"
    end

    -- 3. Convert to PEM
    err = exec.command("openssl", "rsa", "-RSAPublicKey_in", "-inform", "DER", "-in", der_file, "-out", pem_file,
        "-pubout"):run()

    if err then
        exec.command("rm", asn1_file, der_file):run()
        return nil, "rsa conversion failed"
    end

    -- 4. Encrypt password with pkeyutl
    local cmd3 = string.format(
        "echo -n %q | openssl pkeyutl -encrypt -inkey %s -pubin -pkeyopt rsa_padding_mode:pkcs1 2>/dev/null", password,
        pem_file)
    local pipe = io.popen(cmd3, "r")
    if not pipe then
        exec.command("rm", asn1_file, der_file, pem_file):run()
        return nil, "pkeyutl pipe failed"
    end

    local ct = pipe:read("*all")
    pipe:close()

    -- Clean up temp files
    exec.command("rm", asn1_file, der_file, pem_file):run()

    if not ct or #ct == 0 then
        return nil, "openssl pkeyutl failed"
    end

    -- 5. Base64 + URL escape
    local b64 = basexx.to_base64(ct)
    local escaped = urlencode_b64(b64)

    return escaped
end

-- http calls
local function get_ports_info(host)
    local js, err = get_cgi_json(host, "panel_info", true)
    if not js or err then return nil, err end
    return js.data.ports or nil
end

local function get_sys_cpumem(host)
    local js, err = get_cgi_json(host, "sys_cpumem", true)
    if not js or err then return nil, nil, err end
    return js.data.cpu, js.data.mem, nil
end

local function get_sys_time(host)
    local js, err = get_cgi_json(host, "sys_sysTime", true)
    if not js or err then return nil, err end
    return js.data.sysCurrTime or nil, nil
end

local function get_ports_poe_info(host)
    local js, err = get_cgi_json(host, "poe_poe", true)
    if not js or err then return nil, nil, nil, err end
    return js.data.ports, js.data.devPower, js.data.devTemp, nil
end

local function get_modules(host)
    local js, err = get_cgi_json(host, "home_login", false)
    if not js or err then return nil, err end
    return js.data and js.data.modulus or nil
end

local function get_login_status(host)
    local js, err = get_cgi_json(host, "home_loginStatus", false)
    if not js or err then return nil, err end
    return js.data and js.data.status or nil
end

local function post_login(host, username, encoded_pwd)
    local path    = "/cgi/set.cgi?cmd=home_loginAuth"
    local payload = string.format("_ds=1&username=%s&password=%s&_de=1", username, encoded_pwd)
    local headers = {
        ["Content-Type"]     = "application/x-www-form-urlencoded; charset=UTF-8",
        ["X-Requested-With"] = "XMLHttpRequest",
        ["Content-Length"]   = tostring(#payload),
    }
    return post_cgi_json(host, path, payload, headers)
end

-- authenticate_user = get modulus, encrypt password, then post login
local function authenticate_user(host, username, password)
    local mod, err = get_modules(host)
    if not mod then return nil, "failed to fetch modulus: " .. tostring(err) end

    local enc_pwd, perr = encrypt_password(mod, password)
    if not enc_pwd then return nil, "encrypt error: " .. tostring(perr) end

    return post_login(host, username, enc_pwd)
end

-- TODO: handle unable to auth
local function login(host, username, password)
    local _, err = authenticate_user(host, username, password)

    if err then return false, err end

    local tries = 0
    local max_tries = 10

    while tries < max_tries do
        local status, err = get_login_status(host)

        if err then return false, err end
        if status == "ok" then return true end
        if status == "fail" then return false, "login failed incorrect credentials" end

        tries = tries + 1
        sleep.sleep(1)
    end

    return false, "login timeout"
end

local function get_stats(host)
    local stats = {
        ["system"] = {
            ["curr_time"] = 0,
            ["mem"] = 0,
            ["cpu"] = 0,
            ["power"] = 0,
            ["temp"] = 0
        },
        ["ports"] = {},    -- link/speed/etc
        ["ports_poe"] = {} -- PoE status/limits
    }

    local curr_time, err = get_sys_time(host)
    if err then return nil, err end
    stats.system.curr_time = curr_time

    local cpu, mem, err = get_sys_cpumem(host)
    if err then return nil, err end
    stats.system.cpu = cpu
    stats.system.mem = mem

    local ports, err = get_ports_info(host)
    if err then return nil, err end
    stats.ports = ports

    local ports_poe, power, temp, err = get_ports_poe_info(host)
    if err then return nil, err end
    stats.ports_poe = ports_poe
    stats.system.power = power
    stats.system.temp = temp

    return stats, nil
end

return {
    login = login,
    get_stats = get_stats,
}
