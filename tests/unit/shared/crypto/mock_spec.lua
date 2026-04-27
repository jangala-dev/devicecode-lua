local mock = require 'shared.crypto.backends.mock'

local T = {}

function T.mock_backend_succeeds_by_default_and_records_calls()
  local provider = mock.new()
  local ok, err = provider:verify_ed25519('PEM', 'MSG', 'SIG')
  assert(ok == true and err == nil)
  assert(#provider.calls == 1)
  assert(provider.calls[1].pubkey_pem == 'PEM')
end

function T.mock_backend_can_return_configured_failure_or_error()
  local fail = mock.new({ result = false })
  local ok1, err1 = fail:verify_ed25519('PEM', 'MSG', 'SIG')
  assert(ok1 == false and err1 == nil)

  local errp = mock.new({ err = 'backend_down' })
  local ok2, err2 = errp:verify_ed25519('PEM', 'MSG', 'SIG')
  assert(ok2 == nil and err2 == 'backend_down')
end

function T.mock_backend_can_make_verifier()
  local provider = mock.new()
  local verifier = provider:new_verifier({ keyring = { lookup = function() return 'PEM', nil end } })
  local ok, err = verifier:verify_message({ alg = 'ed25519', key_id = 'kid', message = 'M', signature = 'S' })
  assert(ok == true and err == nil)
  assert(#provider.calls == 1)
end

return T
