
local cjson = require 'cjson.safe'
local mcu_image_v1 = require 'services.update.mcu_image_v1'

local T = {}

local function u16le(n)
  local b1 = n % 256
  local b2 = math.floor(n / 256) % 256
  return string.char(b1, b2)
end

local function u32le(n)
  local b1 = n % 256
  local b2 = math.floor(n / 256) % 256
  local b3 = math.floor(n / 65536) % 256
  local b4 = math.floor(n / 16777216) % 256
  return string.char(b1, b2, b3, b4)
end

local function make_image(opts)
  opts = opts or {}
  local payload = opts.payload or 'PAYLOAD'
  local manifest = opts.manifest or {
    schema = 1,
    component = 'mcu',
    target = {
      product_family = 'bigbox',
      hardware_profile = 'bb-v1-cm5-2',
      mcu_board_family = 'rp2354a',
    },
    build = {
      version = 'mcu-v1',
      build_id = '2026.04.24-1',
      image_id = 'mcu-bigbox-1.0+2026.04.24-1',
    },
    payload = {
      format = 'raw-bin',
      length = #payload,
      sha256 = opts.sha256 or string.rep('0', 64),
    },
    signing = {
      key_id = 'test-key',
      sig_alg = 'ed25519',
    },
  }
  local manifest_bytes = cjson.encode(manifest)
  local signature = opts.signature or string.rep('S', 64)
  local magic = opts.magic or 'DCMCUIMG'
  local version = opts.version or 1
  local header_len = opts.header_len or 32
  local signature_len = opts.signature_len or 64
  local payload_len = opts.payload_len or #payload
  local flags = opts.flags or 0
  local reserved = opts.reserved or 0
  local manifest_len = opts.manifest_len or #manifest_bytes
  local header = table.concat({
    magic,
    u16le(version),
    u16le(header_len),
    u32le(manifest_len),
    u32le(signature_len),
    u32le(payload_len),
    u32le(flags),
    u32le(reserved),
  })
  return header .. manifest_bytes .. signature .. payload
end

function T.inspect_valid_image_returns_normalised_manifest()
  local payload = 'hello-firmware'
  local data = make_image({ payload = payload, sha256 = string.rep('a', 64) })
  local out, err = mcu_image_v1.inspect_bytes(data, {
    target = {
      product_family = 'bigbox',
      hardware_profile = 'bb-v1-cm5-2',
      mcu_board_family = 'rp2354a',
    },
  })
  assert(err == nil)
  assert(type(out) == 'table')
  assert(out.format == 'dcmcu-v1')
  assert(out.build.version == 'mcu-v1')
  assert(out.build.build_id == '2026.04.24-1')
  assert(out.payload.length == #payload)
  assert(out.payload.sha256 == string.rep('a', 64))
end

function T.inspect_rejects_bad_magic()
  local out, err = mcu_image_v1.inspect_bytes(make_image({ magic = 'BADCIMG!' }))
  assert(out == nil)
  assert(err == 'bad_magic')
end

function T.inspect_rejects_target_mismatch()
  local out, err = mcu_image_v1.inspect_bytes(make_image(), {
    target = {
      product_family = 'bigbox',
      hardware_profile = 'wrong-profile',
      mcu_board_family = 'rp2354a',
    },
  })
  assert(out == nil)
  assert(err == 'target_hardware_profile_mismatch')
end

function T.inspect_requires_signature_verifier_when_requested()
  local out, err = mcu_image_v1.inspect_bytes(make_image(), { require_signature = true })
  assert(out == nil)
  assert(err == 'signature_verifier_unavailable')
end

function T.inspect_uses_signature_verifier_callback()
  local called = false
  local out, err = mcu_image_v1.inspect_bytes(make_image(), {
    verify_signature = function(rec)
      called = true
      assert(rec.key_id == 'test-key')
      assert(rec.alg == 'ed25519')
      assert(type(rec.message) == 'string' and #rec.message > 0)
      assert(type(rec.signature) == 'string' and #rec.signature == 64)
      return true
    end,
  })
  assert(err == nil)
  assert(type(out) == 'table')
  assert(called == true)
end

return T
