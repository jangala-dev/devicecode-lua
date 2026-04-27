-- shared/crypto/backends/hal_cap.lua
--
-- HAL capability backed crypto provider.  This is the only shared.crypto module
-- that knows how to translate crypto operations into HAL capability calls.

local cap_sdk = require 'services.hal.sdk.cap'
local verifier_mod = require 'shared.crypto.verifier'

local M = {}
local Provider = {}
Provider.__index = Provider

---@param opts { cap: table }
---@return table
function M.new(opts)
	opts = type(opts) == 'table' and opts or {}
	local cap = opts.cap
	assert(cap and type(cap.call_control) == 'function', 'HAL signature verify capability required')
	return setmetatable({ cap = cap, name = opts.name or 'hal_cap' }, Provider)
end

function Provider:verify_ed25519(pubkey_pem, message, signature)
	if type(pubkey_pem) ~= 'string' or pubkey_pem == '' then return nil, 'public_key_required' end
	if type(message) ~= 'string' then return nil, 'message_required' end
	if type(signature) ~= 'string' or signature == '' then return nil, 'signature_required' end

	local opts, oerr = cap_sdk.args.new.SignatureVerifyEd25519Opts(pubkey_pem, message, signature)
	if not opts then return nil, oerr or 'invalid_opts' end

	local reply, err = self.cap:call_control('verify_ed25519', opts)
	if not reply then return nil, err or 'signature_verifier_unavailable' end
	if reply.ok == true then return true, nil end

	local reason = type(reply.reason) == 'string' and reply.reason or tostring(reply.reason or 'verify_failed')
	if reason == 'signature_verify_failed' then return false, reason end
	return nil, reason
end

function Provider:new_verifier(opts)
	opts = type(opts) == 'table' and opts or {}
	local keyring = assert(opts.keyring, 'crypto verifier keyring required')
	return verifier_mod.new({ provider = self, keyring = keyring })
end

return M
