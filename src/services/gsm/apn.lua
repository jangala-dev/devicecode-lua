local binser = require "binser"

-- ask rich what these fellas do
local g_authtypes = {}
g_authtypes["0"] = "none"
g_authtypes["1"] = "pap"
g_authtypes["2"] = "chap"
g_authtypes["3"] = "pap|chap"

-- deserialise the apn database and return the apn for the sim
local function get_apns(mcc, mnc)
    local apndb = binser.r("etc/apns")[1]
    local apns = apndb[mcc][mnc]
    return apns
end

local function build_connection_string(apn, roaming_allow)
    if not apn or next(apn) == nil then return nil, "apn table empty" end
    local a = {}
    for k,v in pairs(apn) do
        if k == "apn" then table.insert(a, "apn="..v)
        elseif k == "user" then table.insert(a, "user="..v)
        elseif k == "password" then table.insert(a, "password="..v)
        elseif k == "authtype" then table.insert(a, "allowed-auth="..g_authtypes[v])
        end
    end
    if roaming_allow then table.insert(a, "allow-roaming=true") end
    local conn_string = table.concat(a,",")
    return conn_string, nil
end

-- the connect function takes a list of apns and applies
local function rank(apns, imsi, spn, gid1)
    -- first comes MVNO matches, next general MNO APNs, then generic "apn=internet", finally non-match MVNO
    local rankings = {}
    for k, v in pairs(apns) do
        -- print("k is: ", k)
        if v.mvno_type then
            -- print("v is: ", v.mvno_type)
            if v.mvno_type == "spn" and spn and string.find(spn, v.mvno_match_data) then
                table.insert(rankings, {name=k, rank=1})
            elseif v.mvno_type == "gid" and gid1 and string.find(gid1, v.mvno_match_data) then
                table.insert(rankings, {name=k, rank=1})
            elseif v.mvno_type == "imsi" and string.find(imsi, v.mvno_match_data) then
                table.insert(rankings, {name=k, rank=1})
            else
                table.insert(rankings, {name=k, rank=4})
            end
        else
            table.insert(rankings, {name=k, rank=2})
        end
    end
    table.insert(apns, {default={apn='internet'}})
    table.insert(rankings, {name='default', rank=3})
    table.sort(rankings, function (k1, k2) return k1.rank < k2.rank end )
    return apns, rankings
end

local function get_ranked_apns(mcc, mnc, imsi, spn, gid1)
    if mnc == nil then return {}, {} end
    if #mnc == 1 then mnc = "0"..mnc end
    -- get apns from the network service
    local apns = get_apns(mcc, mnc)
    -- or read directly
    -- local apns = binser.r("etc/apns")[1]
    local rankapns, rankings = rank(apns, imsi, spn, gid1)
    return rankapns, rankings
end

return {
    get_ranked_apns = get_ranked_apns,
    build_connection_string = build_connection_string
}
