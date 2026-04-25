local artifacts_mod = require 'services.update.artifacts'

local M = {}

function M.fake_mcu_ok(extra)
  extra = type(extra) == 'table' and extra or {}
  return function(_artifacts, _ref, desc, _artifact_spec)
    desc = type(desc) == 'table' and desc or {}
    local m = {
      schema = 1,
      target = {
        product_family = extra.product_family or 'bigbox',
        hardware_profile = extra.hardware_profile or 'bb-v1-cm5-2',
        mcu_board_family = extra.mcu_board_family or 'rp2354a',
      },
      build = {
        version = extra.version or 'mcu-test-v1',
        build_id = extra.build_id or 'test-build-1',
        image_id = extra.image_id or 'mcu-test-v1+test-build-1',
      },
      payload = {
        format = extra.format or 'raw-bin',
        length = extra.length or 7,
        sha256 = extra.sha256 or string.rep('a', 64),
      },
      signing = extra.signing or nil,
    }
    desc.mcu_image = m
    return desc, nil
  end
end

function M.install_fake_mcu_preflight(extra)
  local fn = M.fake_mcu_ok(extra)
  artifacts_mod.set_default_preflighter('mcu', fn)
  return function()
    artifacts_mod.set_default_preflighter('mcu', nil)
  end
end

return M
