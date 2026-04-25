local fibers = require 'fibers'
local observe = require 'services.device.observe'

local M = {}

local function send_required(tx, value, what)
  local ok, reason = tx:send(value)
  if ok ~= true then
    error((what or 'observer_event_send_failed') .. ': ' .. tostring(reason or 'closed'), 0)
  end
end

function M.spawn_component(scope_obj, conn, name, rec, tx, generation)
  local child, err = scope_obj:child()
  if not child then return nil, err end

  local ok, spawn_err = child:spawn(function()
    local function emit(ev)
      ev.component = ev.component or name
      ev.generation = generation
      send_required(tx, ev, 'observer_event_overflow')
    end

    local st, _report, primary = fibers.run_scope(function()
      return observe.run({
        conn = conn,
        component = name,
        rec = rec,
        generation = generation,
        emit = emit,
      })
    end)

    if st == 'failed' then
      emit({ tag = 'source_down', reason = tostring(primary or 'provider_failed') })
      error(primary or 'provider_failed', 0)
    end
  end)

  if not ok then return nil, spawn_err end

  return {
    component = name,
    generation = generation,
    scope = child,
  }, nil
end

return M
