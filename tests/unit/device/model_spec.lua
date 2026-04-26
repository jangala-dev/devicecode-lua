local model = require 'services.device.model'

local T = {}

local function new_state()
  local state = model.new_state('devicecode.config/device/1')
  model.apply_cfg(state, {
    schema = 'devicecode.config/device/1',
    components = {
      mcu = {
        facts = {
          software = { 'raw', 'member', 'mcu', 'state', 'software' },
        },
      },
    },
  })
  model.clear_component_dirty(state, 'mcu')
  model.set_summary_clean(state)
  return state
end

function T.device_model_dedupes_identical_fact_updates()
  local state = new_state()
  model.note_fact(state, 'mcu', 'software', { version = 'v1' }, 10)
  assert(state.dirty_components.mcu == true)
  model.clear_component_dirty(state, 'mcu')
  model.set_summary_clean(state)

  model.note_fact(state, 'mcu', 'software', { version = 'v1' }, 10)
  assert(state.dirty_components.mcu == nil)
  assert(state.summary_dirty == false)

  model.note_fact(state, 'mcu', 'software', { version = 'v2' }, 10)
  assert(state.dirty_components.mcu == true)
end

function T.device_model_dedupes_repeated_source_down_with_same_reason()
  local state = new_state()
  model.note_source_down(state, 'mcu', 'stale')
  assert(state.dirty_components.mcu == true)
  model.clear_component_dirty(state, 'mcu')
  model.set_summary_clean(state)

  model.note_source_down(state, 'mcu', 'stale')
  assert(state.dirty_components.mcu == nil)
  assert(state.summary_dirty == false)

  model.note_source_down(state, 'mcu', 'closed')
  assert(state.dirty_components.mcu == true)
end

return T
