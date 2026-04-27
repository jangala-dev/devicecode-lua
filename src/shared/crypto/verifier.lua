-- shared/crypto/verifier.lua

local M = {}
local Verifier = {}
Verifier.__index = Verifier

function Verifier:verify_message(spec)
	if type(spec) ~= 'table' then return nil, 'verify_spec_required' end
	if spec.alg ~= 'ed25519' then return nil, 'signature_algorithm_unsupported' end
	local pem, kerr = self.keyring:lookup(spec.key_id)
	if not pem then return nil, kerr or 'unknown_key_id' end
	return self.provider:verify_ed25519(pem, spec.message, spec.signature)
end

function M.new(opts)
	opts = type(opts) == 'table' and opts or {}
	assert(opts.provider and type(opts.provider.verify_ed25519) == 'function', 'verifier provider required')
	assert(opts.keyring and type(opts.keyring.lookup) == 'function', 'verifier keyring required')
	return setmetatable({ provider = opts.provider, keyring = opts.keyring }, Verifier)
end

return M
