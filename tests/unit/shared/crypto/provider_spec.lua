local provider_mod = require 'shared.crypto.provider'

local T = {}

function T.new_requires_backend_with_crypto_shape()
  local ok1 = pcall(function() provider_mod.new() end)
  assert(ok1 == false)
  local ok2 = pcall(function() provider_mod.new({ backend = {} }) end)
  assert(ok2 == false)

  local backend = { new_verifier = function() end }
  local got = provider_mod.new({ backend = backend })
  assert(got == backend)

  local backend2 = { verify_ed25519 = function() end }
  local got2 = provider_mod.new({ backend = backend2 })
  assert(got2 == backend2)
end

function T.with_verifier_factory_returns_backend_that_already_has_factory()
  local backend = { new_verifier = function() return 'ok' end }
  local got = provider_mod.with_verifier_factory(backend)
  assert(got == backend)
end

function T.with_verifier_factory_wraps_operation_provider()
  local seen = {}
  local provider = provider_mod.with_verifier_factory({
    verify_ed25519 = function(_, pem, msg, sig)
      seen.pem = pem
      seen.msg = msg
      seen.sig = sig
      return true, nil
    end,
  })
  local verifier = provider:new_verifier({
    keyring = { lookup = function(_, key_id)
      assert(key_id == 'kid')
      return 'PEM', nil
    end },
  })
  local ok, err = verifier:verify_message({ alg = 'ed25519', key_id = 'kid', message = 'MSG', signature = 'SIG' })
  assert(ok == true and err == nil)
  assert(seen.pem == 'PEM')
  assert(seen.msg == 'MSG')
  assert(seen.sig == 'SIG')
end

return T
