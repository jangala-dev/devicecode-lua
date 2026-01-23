local M = {}

-- Simple in-memory registry used by the test modem backends to
-- map mmcli modem addresses and QMI ports back to the dummy modem
-- instance that owns them.

local by_address = {}
local by_qmi_port = {}

local function clear_mapping(map, modem)
    for k, v in pairs(map) do
        if v == modem then
            map[k] = nil
        end
    end
end

function M.set_address(modem, address)
    if not modem or not address then return end
    -- Remove any previous mapping for this modem to avoid stale keys.
    clear_mapping(by_address, modem)
    by_address[address] = modem
end

function M.set_qmi_port(modem, port)
    if not modem or not port then return end
    clear_mapping(by_qmi_port, modem)
    by_qmi_port[port] = modem
end

function M.get_by_address(address)
    return by_address[address]
end

function M.get_by_qmi_port(port)
    return by_qmi_port[port]
end

return M
