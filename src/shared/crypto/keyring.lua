-- shared/crypto/keyring.lua

local M = {}
local MapKeyring = {}
MapKeyring.__index = MapKeyring

local function normalise_entry(entry)
	if type(entry) == 'string' and entry ~= '' then
		return { public_key_pem = entry }
	end
	if type(entry) ~= 'table' then return nil end
	local pem = entry.public_key_pem or entry.pem
	if type(pem) ~= 'string' or pem == '' then return nil end
	return {
		public_key_pem = pem,
		alg = entry.alg or entry.sig_alg,
	}
end

function MapKeyring:lookup(key_id)
	if type(key_id) ~= 'string' or key_id == '' then return nil, 'key_id_required' end
	local entry = self._keys[key_id]
	if not entry then return nil, 'unknown_key_id' end
	return entry.public_key_pem, nil, entry
end

function M.from_config(cfg)
	local keys = {}
	if type(cfg) ~= 'table' then
		return setmetatable({ _keys = keys }, MapKeyring)
	end
	local src = cfg.trusted_keys or cfg.keys or cfg
	if type(src) == 'table' then
		for key_id, entry in pairs(src) do
			if type(key_id) == 'string' and key_id ~= '' then
				local rec = normalise_entry(entry)
				if rec then keys[key_id] = rec end
			end
		end
	end
	return setmetatable({ _keys = keys }, MapKeyring)
end

return M
