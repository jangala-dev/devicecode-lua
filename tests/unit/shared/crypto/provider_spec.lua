local provider_mod = require 'shared.crypto.provider'
local cap_sdk = require 'services.hal.sdk.cap'

local T = {}

function T.from_cap_requires_capability_reference()
  local ok = pcall(function() provider_mod.from_cap(nil) end)
  assert(ok == false)

  local ok2 = pcall(function() provider_mod.from_cap({}) end)
  assert(ok2 == false)

  local provider = provider_mod.from_cap({
    call_control = function() return { ok = true, reason = true }, nil end,
  })
  assert(type(provider) == 'table')
  assert(type(provider.verify_ed25519) == 'function')
end

function T.verify_ed25519_validates_inputs_before_calling_capability()
  local calls = 0
  local provider = provider_mod.from_cap({
    call_control = function() calls = calls + 1 end,
  })

  local ok1, err1 = provider:verify_ed25519(nil, 'm', 's')
  assert(ok1 == nil and err1 == 'public_key_required')
  local ok2, err2 = provider:verify_ed25519('PEM', nil, 's')
  assert(ok2 == nil and err2 == 'message_required')
  local ok3, err3 = provider:verify_ed25519('PEM', 'm', nil)
  assert(ok3 == nil and err3 == 'signature_required')
  assert(calls == 0)
end

function T.verify_ed25519_maps_success_negative_and_error_replies()
  local seen_method, seen_opts
  local replies = {
    { ok = true, reason = true },
    { ok = false, reason = 'signature_verify_failed' },
    { ok = false, reason = 'openssl_verify_failed:bad usage' },
  }
  local provider = provider_mod.from_cap({
    call_control = function(_, method, opts)
      seen_method, seen_opts = method, opts
      return table.remove(replies, 1), nil
    end,
  })

  local ok1, err1 = provider:verify_ed25519('PEM', 'MSG', 'SIG')
  assert(ok1 == true and err1 == nil)
  assert(seen_method == 'verify_ed25519')
  assert(getmetatable(seen_opts) == cap_sdk.args.SignatureVerifyEd25519Opts)

  local ok2, err2 = provider:verify_ed25519('PEM', 'MSG', 'SIG')
  assert(ok2 == false and err2 == 'signature_verify_failed')

  local ok3, err3 = provider:verify_ed25519('PEM', 'MSG', 'SIG')
  assert(ok3 == nil and err3 == 'openssl_verify_failed:bad usage')
end

function T.verify_ed25519_propagates_transport_failure()
  local provider = provider_mod.from_cap({
    call_control = function() return nil, 'no_route' end,
  })
  local ok, err = provider:verify_ed25519('PEM', 'MSG', 'SIG')
  assert(ok == nil)
  assert(err == 'no_route')
end

return T
