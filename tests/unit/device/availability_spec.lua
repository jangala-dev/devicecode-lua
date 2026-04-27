local availability = require 'services.device.availability'

local T = {}

function T.availability_helper_uses_required_facts_for_ready()
  local rec = {
    fact_state = {
      software = { seen = true },
      updater = { seen = false },
    },
  }

  assert(availability.any_observation_seen(rec) == true)
  assert(availability.required_facts_ready(rec, { 'software', 'updater' }) == false)
  assert(availability.required_facts_ready(rec, { 'software' }) == true)
end

function T.availability_helper_uses_any_seen_when_no_required_facts()
  local rec = {
    fact_state = {
      updater = { seen = true },
    },
  }

  assert(availability.any_observation_seen(rec) == true)
  assert(availability.required_facts_ready(rec, nil) == true)
  assert(availability.required_facts_ready(rec, {}) == true)
end

function T.availability_helper_marks_unseen_when_no_observations()
  local rec = {
    fact_state = {
      software = { seen = false },
    },
    event_state = {
      charger_alert = { seen = false },
    },
  }

  assert(availability.any_observation_seen(rec) == false)
  assert(availability.required_facts_ready(rec, nil) == false)
end

return T
