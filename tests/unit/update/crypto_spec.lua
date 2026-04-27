local crypto_mod = require 'services.update.crypto'
local mock_backend = require 'shared.crypto.backends.mock'

local T = {}

function T.needs_verifier_when_required_or_keys_present()
  assert(crypto_mod.needs_verifier({ require_signature = true }) == true)
  assert(crypto_mod.needs_verifier({ trusted_keys = { kid = 'PEM' } }) == true)
  assert(crypto_mod.needs_verifier({ keys = { kid = 'PEM' } }) == true)
  assert(crypto_mod.needs_verifier({}) == false)
  assert(crypto_mod.needs_verifier(nil) == false)
end

function T.verifier_for_preflight_returns_nil_when_not_needed()
  local c = crypto_mod.new({ provider = mock_backend.new() })
  local v, err = c:verifier_for_preflight({})
  assert(v == nil and err == nil)
end

function T.verifier_for_preflight_requires_provider_when_needed()
  local c = crypto_mod.new({})
  local v, err = c:verifier_for_preflight({ require_signature = true })
  assert(v == nil and err == 'signature_verifier_unavailable')
end

function T.verifier_for_preflight_builds_injected_verifier()
  local provider = mock_backend.new()
  local c = crypto_mod.new({ provider = provider })
  local v, err = c:verifier_for_preflight({
    trusted_keys = { kid = 'PEM' },
  })
  assert(err == nil)
  assert(type(v) == 'table')
  local ok, verr = v:verify_message({ alg = 'ed25519', key_id = 'kid', message = 'M', signature = 'S' })
  assert(ok == true and verr == nil)
  assert(#provider.calls == 1)
end

return T
