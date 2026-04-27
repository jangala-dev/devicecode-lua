local verifier_mod = require 'shared.crypto.verifier'

local T = {}

function T.new_requires_provider_and_keyring()
  local ok1 = pcall(function() verifier_mod.new({}) end)
  assert(ok1 == false)
  local ok2 = pcall(function() verifier_mod.new({ provider = {} }) end)
  assert(ok2 == false)
  local ok3 = pcall(function()
    verifier_mod.new({ provider = { verify_ed25519 = function() end }, keyring = { lookup = function() end } })
  end)
  assert(ok3 == true)
end

function T.verify_message_rejects_missing_spec_and_unsupported_alg()
  local verifier = verifier_mod.new({
    provider = { verify_ed25519 = function() return true end },
    keyring = { lookup = function() return 'PEM', nil end },
  })
  local ok1, err1 = verifier:verify_message(nil)
  assert(ok1 == nil)
  assert(err1 == 'verify_spec_required')
  local ok2, err2 = verifier:verify_message({ alg = 'rsa' })
  assert(ok2 == nil)
  assert(err2 == 'signature_algorithm_unsupported')
end

function T.verify_message_propagates_key_lookup_failure()
  local verifier = verifier_mod.new({
    provider = { verify_ed25519 = function() return true end },
    keyring = { lookup = function() return nil, 'unknown_key_id' end },
  })
  local ok, err = verifier:verify_message({ alg = 'ed25519', key_id = 'missing', message = 'm', signature = 's' })
  assert(ok == nil)
  assert(err == 'unknown_key_id')
end

function T.verify_message_delegates_to_provider()
  local seen = {}
  local verifier = verifier_mod.new({
    provider = {
      verify_ed25519 = function(_, pem, message, signature)
        seen.pem = pem
        seen.message = message
        seen.signature = signature
        return true, nil
      end,
    },
    keyring = {
      lookup = function(_, key_id)
        assert(key_id == 'kid-1')
        return 'PEM-1', nil, { alg = 'ed25519' }
      end,
    },
  })
  local ok, err = verifier:verify_message({ alg = 'ed25519', key_id = 'kid-1', message = 'manifest', signature = 'sig' })
  assert(ok == true)
  assert(err == nil)
  assert(seen.pem == 'PEM-1')
  assert(seen.message == 'manifest')
  assert(seen.signature == 'sig')
end

return T
