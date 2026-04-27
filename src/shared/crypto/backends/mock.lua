-- shared/crypto/backends/mock.lua
--
-- Test/deterministic crypto provider.  It is deliberately small and records
-- calls so tests can assert the verifier path without a HAL capability.

local verifier_mod = require 'shared.crypto.verifier'

local M = {}
local Provider = {}
Provider.__index = Provider

---@param opts? { result: any, err: any, by_key: table, on_verify: function }
---@return table
function M.new(opts)
	opts = type(opts) == 'table' and opts or {}
	return setmetatable({
		result = opts.result,
		err = opts.err,
		by_key = type(opts.by_key) == 'table' and opts.by_key or nil,
		on_verify = opts.on_verify,
		calls = {},
	}, Provider)
end

function Provider:verify_ed25519(pubkey_pem, message, signature)
	local call = { pubkey_pem = pubkey_pem, message = message, signature = signature }
	self.calls[#self.calls + 1] = call
	if type(self.on_verify) == 'function' then
		return self.on_verify(self, call)
	end
	if self.err ~= nil then return nil, self.err end
	if self.result ~= nil then return self.result, nil end
	return true, nil
end

function Provider:new_verifier(opts)
	opts = type(opts) == 'table' and opts or {}
	local keyring = assert(opts.keyring, 'crypto verifier keyring required')
	return verifier_mod.new({ provider = self, keyring = keyring })
end

return M
