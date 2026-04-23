local availability = require 'services.device.availability'

local T = {}

function T.availability_helper_uses_required_facts_for_ready()
  local rec = {
    fact_state = {
      software = { seen = true },
      updater = { seen = false },
    },
  }
  local st = availability.source_status(rec, { required_facts = { 'software', 'updater' } })
  assert(st.available == true)
  assert(st.ready == false)
end

function T.availability_helper_marks_stale_source()
  local rec = { source_err = 'stale' }
  local st = availability.source_status(rec, {})
  assert(st.stale == true)
end

return T
