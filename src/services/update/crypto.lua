-- services/update/crypto.lua
--
-- Update-local crypto wiring.  Update owns policy: when a verifier is needed
-- and which keys are trusted.  The crypto backend is injectable; the default
-- backend is a raw HAL host capability adapter.

local keyring_mod = require 'shared.crypto.keyring'

local M = {}
local Crypto = {}
Crypto.__index = Crypto

local function has_trusted_keys(preflight)
	local trusted = type(preflight) == 'table' and (preflight.trusted_keys or preflight.keys) or nil
	return type(trusted) == 'table' and next(trusted) ~= nil
end

local function needs_verifier(preflight)
	return type(preflight) == 'table' and (preflight.require_signature == true or has_trusted_keys(preflight))
end

local function default_hal_provider(opts)
	local raw_cap = opts.raw_cap
	if not raw_cap and opts.conn then
		local cap_sdk = require 'services.hal.sdk.cap'
		raw_cap = cap_sdk.new_raw_host_cap_ref(opts.conn, 'signature-verify', 'signature-verify', 'main')
	end
	if raw_cap then
		local hal_cap_backend = require 'shared.crypto.backends.hal_cap'
		return hal_cap_backend.new({ cap = raw_cap })
	end
	return nil
end

---@param opts { provider: table?, raw_cap: table?, conn: table? }
---@return table
function M.new(opts)
	opts = type(opts) == 'table' and opts or {}
	local provider = opts.provider or default_hal_provider(opts)
	return setmetatable({ provider = provider }, Crypto)
end

function Crypto:verifier_for_preflight(preflight)
	preflight = type(preflight) == 'table' and preflight or {}
	if not needs_verifier(preflight) then return nil, nil end
	if not self.provider then return nil, 'signature_verifier_unavailable' end
	local keyring = keyring_mod.from_config(preflight)
	if type(self.provider.new_verifier) ~= 'function' then return nil, 'signature_verifier_unavailable' end
	return self.provider:new_verifier({ keyring = keyring, trusted_keys = preflight.trusted_keys or preflight.keys })
end

M.needs_verifier = needs_verifier

return M
