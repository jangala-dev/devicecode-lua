local keyring = require 'shared.crypto.keyring'

local T = {}

function T.from_config_accepts_string_entries_and_lookup_returns_pem_and_meta()
  local kr = keyring.from_config({
    trusted_keys = {
      ['k1'] = 'PEM-1',
    },
  })
  local pem, err, meta = kr:lookup('k1')
  assert(err == nil)
  assert(pem == 'PEM-1')
  assert(type(meta) == 'table')
  assert(meta.public_key_pem == 'PEM-1')
end

function T.from_config_accepts_table_entries_with_alias_fields()
  local kr = keyring.from_config({
    trusted_keys = {
      ['k2'] = { pem = 'PEM-2', sig_alg = 'ed25519' },
    },
  })
  local pem, err, meta = kr:lookup('k2')
  assert(err == nil)
  assert(pem == 'PEM-2')
  assert(meta.alg == 'ed25519')
end

function T.lookup_rejects_missing_and_unknown_key_ids()
  local kr = keyring.from_config({ trusted_keys = { ok = 'PEM' } })
  local pem1, err1 = kr:lookup(nil)
  assert(pem1 == nil)
  assert(err1 == 'key_id_required')
  local pem2, err2 = kr:lookup('missing')
  assert(pem2 == nil)
  assert(err2 == 'unknown_key_id')
end

function T.from_config_ignores_invalid_entries()
  local kr = keyring.from_config({
    trusted_keys = {
      bad1 = true,
      bad2 = {},
      ok = { public_key_pem = 'PEM-OK' },
    },
  })
  local pem_bad = kr:lookup('bad1')
  assert(pem_bad == nil)
  local pem_ok, err_ok = kr:lookup('ok')
  assert(err_ok == nil)
  assert(pem_ok == 'PEM-OK')
end

return T
