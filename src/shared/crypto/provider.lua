-- shared/crypto/provider.lua

local cap_sdk = require 'services.hal.sdk.cap'

local M = {}
local Provider = {}
Provider.__index = Provider

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
	if reason == 'signature_verify_failed' then
		return false, reason
	end
	return nil, reason
end

function M.from_cap(cap)
	assert(cap and type(cap.call_control) == 'function', 'signature verify capability required')
	return setmetatable({ cap = cap, name = 'hal_signature_verify' }, Provider)
end

return M
