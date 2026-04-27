local observe = require "services.update.observe"

local T = {}

function T.update_observer_dedupes_equal_component_payloads()
  local o = observe.new()
  local v0 = o:version()
  o:note_component('mcu', { software = { version = 'v1' }, updater = { state = 'running' } })
  local v1 = o:version()
  assert(v1 > v0)
  o:note_component('mcu', { software = { version = 'v1' }, updater = { state = 'running' } })
  assert(o:version() == v1)
  o:note_component('mcu', { software = { version = 'v2' }, updater = { state = 'running' } })
  assert(o:version() > v1)
end

function T.update_observer_clear_only_signals_when_state_changes()
  local o = observe.new()
  local v0 = o:version()
  o:clear_component('mcu')
  assert(o:version() == v0)
  o:note_component('mcu', { software = { version = 'v1' } })
  local v1 = o:version()
  o:clear_component('mcu')
  assert(o:version() > v1)
  local v2 = o:version()
  o:clear_component('mcu')
  assert(o:version() == v2)
end

return T
