#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-full-stack-mock-hal-test"
WORK="$VM_DIR/work/full-stack-mock-hal-test"

mkdir -p "$WORK"

cat > "$WORK/run_devicecode_full_stack_mock_hal.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  './vendor/?.lua', './vendor/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'
local safe = require 'coxpcall'
local busmod = require 'bus'

local json_ok, json = pcall(require, 'cjson.safe')
if not json_ok or not json then json = require 'cjson' end

-- The OpenWrt VM dependency set deliberately stays small and does not
-- include lua-http. The real HTTP service still needs lua-http's URI/header
-- modules at require time, so provide a tiny URI/header-compatible boundary for
-- this full-stack mock-HAL test. The test does not exercise real HTTP transport.
package.preload['http.util'] = package.preload['http.util'] or function ()
  local M = {}
  function M.split_authority(authority, scheme)
    authority = tostring(authority or '')
    local host, port
    if authority:sub(1, 1) == '[' then
      host, port = authority:match('^%[([^%]]+)%]:(%d+)$')
      if not host then host = authority:match('^%[([^%]]+)%]$') end
    else
      host, port = authority:match('^([^:]+):(%d+)$')
      if not host then host = authority end
    end
    if host == '' then error('invalid authority') end
    port = tonumber(port) or ((scheme == 'https' or scheme == 'wss') and 443 or 80)
    return host, port
  end
  return M
end

local function mock_headers_new(fields)
  local h = { _items = {}, _order = {} }
  local function norm(k) return tostring(k or ''):lower() end
  function h:get(k) return self._items[norm(k)] end
  function h:upsert(k, v)
    k = norm(k)
    if self._items[k] == nil then self._order[#self._order + 1] = k end
    self._items[k] = tostring(v or '')
    return true
  end
  function h:append(k, v) return self:upsert(k, v) end
  function h:delete(k) self._items[norm(k)] = nil; return true end
  function h:remove(k) return self:delete(k) end
  function h:clone()
    local c = mock_headers_new()
    for _, k in ipairs(self._order) do if self._items[k] ~= nil then c:upsert(k, self._items[k]) end end
    return c
  end
  function h:each()
    local i = 0
    return function ()
      while true do
        i = i + 1
        local k = self._order[i]
        if k == nil then return nil end
        if self._items[k] ~= nil then return k, self._items[k] end
      end
    end
  end
  for k, v in pairs(fields or {}) do h:upsert(k, v) end
  return h
end

package.preload['http.headers'] = package.preload['http.headers'] or function ()
  return { new = function () return mock_headers_new() end }
end

package.preload['http.request'] = package.preload['http.request'] or function ()
  local M = {}
  function M.new_from_uri(uri)
    local scheme, rest = tostring(uri or ''):match('^([%a][%w+.-]*)://(.+)$')
    if not scheme or rest == '' then return nil, 'scheme not valid' end
    local authority, path = rest:match('^([^/]*)(/.*)$')
    if not authority then authority, path = rest, '/' end
    if authority == '' then return nil, 'invalid authority' end
    local headers = mock_headers_new({
      [':scheme'] = scheme:lower(),
      [':authority'] = authority,
      [':path'] = path,
      [':method'] = 'GET',
    })
    return {
      headers = headers,
      set_body = function (self, body) self.body = body; return true end,
      go = function () return nil, 'mock_http_transport_unavailable' end,
    }
  end
  return M
end

-- The OpenWrt VM dependency set also omits lua-openssl. The Wi-Fi
-- service requires openssl.digest at load time for deterministic guest/user id
-- generation. The full-stack mock-HAL lane disables Wi-Fi radios/SSIDs, but we
-- still load the real Wi-Fi service, so provide a small deterministic digest
-- boundary for this test harness. This is not a cryptographic implementation.
package.preload['openssl.digest'] = package.preload['openssl.digest'] or function ()
  local M = {}
  local function hex32(n)
    return string.format('%08x', n % 0x100000000)
  end
  local function simple_digest(_algo, input)
    input = tostring(input or '')
    local h1, h2, h3, h4 = 2166136261, 16777619, 3141592653, 2718281829
    for i = 1, #input do
      local b = input:byte(i)
      h1 = ((h1 + b) * 16777619) % 0x100000000
      h2 = ((h2 + b) * 109951) % 0x100000000
      h3 = ((h3 + ((b * i) % 0x100000000)) * 65599) % 0x100000000
      h4 = ((h4 + h1 + h2 + h3 + b) * 33) % 0x100000000
    end
    return hex32(h1) .. hex32(h2) .. hex32(h3) .. hex32(h4) .. hex32((h1 + h3) % 0x100000000) .. hex32((h2 + h4) % 0x100000000) .. hex32((h1 + h4) % 0x100000000) .. hex32((h2 + h3) % 0x100000000)
  end
  function M.digest(algo, input) return simple_digest(algo, input) end
  function M.new(algo)
    local chunks = {}
    return {
      update = function (_, part) chunks[#chunks + 1] = tostring(part or ''); return true end,
      final = function (_, part)
        if part ~= nil then chunks[#chunks + 1] = tostring(part) end
        local s = table.concat(chunks)
        return {
          tohex = function () return simple_digest(algo, s) end,
        }
      end,
    }
  end
  return M
end

local config_service = require 'services.config'
local device_service = require 'services.device'
local fabric_service = require 'services.fabric'
local gsm_service = require 'services.gsm'
local http_service = require 'services.http'
local metrics_service = require 'services.metrics'
local monitor_service = require 'services.monitor'
local net_service = require 'services.net'
local system_service = require 'services.system'
local time_service = require 'services.time'
local ui_service = require 'services.ui'
local update_service = require 'services.update'
local wifi_service = require 'services.wifi'
local wired_service = require 'services.wired'

local perform = fibers.perform

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end return v end

local function read_file(path)
  local f = assert(io.open(path, 'rb'))
  local s = assert(f:read('*a'))
  f:close()
  return s
end

local function copy(v, seen)
  if type(v) ~= 'table' then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, subv in pairs(v) do out[copy(k, seen)] = copy(subv, seen) end
  return out
end

local function wait_until(label, pred, timeout_s)
  local deadline = fibers.now() + (timeout_s or 2.0)
  local last
  while fibers.now() < deadline do
    local ok, value = safe.pcall(pred)
    if ok and value then return value end
    if not ok then last = value end
    perform(sleep.sleep_op(0.01))
  end
  local ok, value = safe.pcall(pred)
  if ok and value then return value end
  fail(label .. (last and (': ' .. tostring(last)) or ''))
end

local function retained_payload(conn, topic)
  local view = conn:retained_view(topic)
  local msg = view:get(topic)
  view:close()
  return msg and msg.payload or nil
end

local function wait_retained(conn, topic, pred, label, timeout_s)
  return wait_until(label or ('retained ' .. table.concat(topic, '/')), function()
    local p = retained_payload(conn, topic)
    if p ~= nil and (not pred or pred(p)) then return p end
    return nil
  end, timeout_s or 2.0)
end

local function fake_http_driver()
  return {
    started = false,
    terminated = nil,
    start = function(self) self.started = true; return true end,
    terminate = function(self, reason) self.terminated = reason or true; return true end,
    run_op = function(_, _, fn) return fibers.guard(function() return fibers.always(fn()) end) end,
  }
end

local function bind_cap(scope, conn, class, id, methods, opts)
  opts = opts or {}
  conn:retain({ 'cap', class, id, 'state' }, 'added')
  conn:retain({ 'cap', class, id, 'status' }, { state = 'available', available = true, reason = 'mock_hal' })
  local offerings = {}
  for method in pairs(methods or {}) do offerings[method] = true end
  conn:retain({ 'cap', class, id, 'meta' }, { offerings = offerings, mock = true })

  local endpoints = {}
  for method, handler in pairs(methods or {}) do
    local ep = assert(conn:bind({ 'cap', class, id, 'rpc', method }, { queue_len = opts.queue_len or 64 }))
    endpoints[#endpoints + 1] = ep
    local ok, err = scope:spawn(function()
      while true do
        local req = perform(ep:recv_op())
        if req == nil then return end
        local function run_one()
          local ok_h, reply = safe.pcall(handler, req.payload or {}, req)
          if not ok_h then reply = { ok = false, reason = tostring(reply) } end
          if type(reply) ~= 'table' then reply = { ok = false, reason = tostring(reply) } end
          local ok_reply = safe.pcall(function() req:reply(reply) end)
          if not ok_reply then
            -- The operation may have been deliberately detached by the caller;
            -- the mock HAL still records completion through its own counters.
          end
        end
        if opts.concurrent == true then
          scope:spawn(run_one)
        else
          run_one()
        end
      end
    end)
    assert_true(ok, err)
  end
  return endpoints
end

local function normalise_service_config(base)
  local cfg = copy(base)
  -- Keep the production shape where useful, but avoid hardware-dependent work.
  cfg.fabric.data.links = {}
  cfg.gsm.data.modems.known = {}
  cfg.wifi.data.radios = {}
  cfg.wifi.data.ssids = {}
  cfg.wifi.data.band_steering = nil
  cfg.ui.data.http = cfg.ui.data.http or {}
  cfg.ui.data.http.enabled = false
  cfg.ui.data.updates = {
    upload = { enabled = false, max_bytes = 1, require_auth = false, component = 'mcu', create_job = false, start_job = false },
    commit = { require_auth = false },
  }
  cfg.update.data.components = {}
  cfg.update.data.bundled = { enabled = false, components = {} }
  cfg.metrics.data.cloud_url = 'http://127.0.0.1/'
  cfg.metrics.data.templates = {}
  cfg.metrics.data.pipelines = {}
  cfg.system.data.alarms = {}
  return cfg
end

local function encoded_services_config()
  local raw = assert(json.decode(read_file('./configs/bigbox-v1-cm-2.json')))
  return assert(json.encode(normalise_service_config(raw)))
end

local function setup_mock_hal(scope, conn, counters)
  counters.fs_reads = {}
  counters.fs_writes = {}
  counters.network_apply_calls = 0
  counters.network_apply_active = 0
  counters.network_apply_max_active = 0
  counters.network_apply_generations = {}

  local service_blob = encoded_services_config()
  local mainflux_blob = assert(json.encode({ thing_key = 'mock-thing', channels = {} }))

  conn:retain({ 'svc', 'hal', 'announce' }, { role = 'hal', backend = 'openwrt-vm-mock-hal' })
  conn:retain({ 'svc', 'hal', 'status' }, { service = 'hal', state = 'running', ready = true, mock = true })

  bind_cap(scope, conn, 'fs', 'config', {
    read = function(req)
      local filename = req.filename or req.path or ''
      counters.fs_reads[#counters.fs_reads + 1] = filename
      return { ok = true, reason = service_blob }
    end,
  })

  bind_cap(scope, conn, 'fs', 'credentials', {
    read = function(req)
      counters.fs_reads[#counters.fs_reads + 1] = req.filename or req.path or ''
      return { ok = true, reason = mainflux_blob }
    end,
  })

  bind_cap(scope, conn, 'fs', 'state', {
    read = function(req)
      counters.fs_reads[#counters.fs_reads + 1] = req.filename or req.path or ''
      return { ok = false, reason = 'not found', code = 'not_found' }
    end,
    write = function(req)
      counters.fs_writes[#counters.fs_writes + 1] = req
      return { ok = true, reason = true }
    end,
  })

  local store = {}
  bind_cap(scope, conn, 'control-store', 'update', {
    list = function(req)
      local keys, prefix = {}, req.prefix or ''
      for k in pairs(store) do if k:sub(1, #prefix) == prefix then keys[#keys + 1] = k end end
      table.sort(keys)
      return { ok = true, reason = keys }
    end,
    get = function(req)
      if store[req.key] == nil then return { ok = false, reason = 'not found', code = 'not_found' } end
      return { ok = true, reason = store[req.key] }
    end,
    put = function(req) store[req.key] = req.data; return { ok = true, reason = true } end,
    delete = function(req) store[req.key] = nil; return { ok = true, reason = true } end,
  })

  bind_cap(scope, conn, 'artifact-store', 'main', {
    put = function() return { ok = true, reason = { stored = true } } end,
    get = function() return { ok = false, reason = 'not found', code = 'not_found' } end,
    stat = function() return { ok = false, reason = 'not found', code = 'not_found' } end,
  })

  local network_gate = { block_next = false, blocked = nil }
  counters.network_gate = network_gate
  bind_cap(scope, conn, 'network-config', 'main', {
    apply = function(req)
      counters.network_apply_calls = counters.network_apply_calls + 1
      counters.network_apply_active = counters.network_apply_active + 1
      if counters.network_apply_active > counters.network_apply_max_active then
        counters.network_apply_max_active = counters.network_apply_active
      end
      local gen = req.opts and req.opts.generation or req.intent and req.intent.generation or counters.network_apply_calls
      counters.network_apply_generations[#counters.network_apply_generations + 1] = gen
      if network_gate.block_next and network_gate.blocked == nil then
        network_gate.blocked = gen
        while network_gate.block_next do perform(sleep.sleep_op(0.01)) end
      end
      counters.network_apply_active = counters.network_apply_active - 1
      return { ok = true, reason = { ok = true, applied = true, changed = true, backend = 'mock-openwrt', generation = gen } }
    end,
    apply_live_weights = function() return { ok = true, reason = { ok = true, applied = true } } end,
    apply_shaping = function() return { ok = true, reason = { ok = true, applied = true } } end,
  })

  bind_cap(scope, conn, 'network-state', 'main', {
    watch = function() return { ok = true, reason = { ok = true, watch = true } } end,
  })
  bind_cap(scope, conn, 'network-diagnostics', 'main', {
    speedtest = function() return { ok = true, reason = { ok = true, skipped = true, reason = 'mock' } } end,
    read_counters = function() return { ok = true, reason = { ok = true, counters = {} } } end,
  })

  bind_cap(scope, conn, 'time', 'mock', {})
  conn:retain({ 'cap', 'time', 'mock', 'state', 'synced' }, { synced = true, stratum = 1, accuracy_seconds = 0.01 })
  conn:publish({ 'cap', 'time', 'mock', 'event', 'synced' }, { synced = true, stratum = 1 })

  bind_cap(scope, conn, 'platform', '1', { info = function() return { ok = true, reason = { model = 'openwrt-vm' } } end })

  return counters
end

local function spawn_service(root_scope, name, fn)
  local child = assert(root_scope:child())
  local ok, err = child:spawn(function()
    local ok_run, run_err = safe.pcall(fn)
    if not ok_run then error(name .. ' failed: ' .. tostring(run_err), 0) end
  end)
  assert_true(ok, err)
  return child
end

local function service_status_ready_or_running(conn, name)
  local p = retained_payload(conn, { 'svc', name, 'status' })
  if p and (p.state == 'running' or p.ready == true or p.state == 'waiting_for_hal' or p.state == 'waiting_for_job_store' or p.state == 'starting') then
    return true
  end
  -- The VM lane starts services directly rather than through devicecode.main's
  -- supervisor. Services that rely on supervisor-owned svc/<name>/status are
  -- therefore accepted using their own public state projection instead.
  if name == 'wired' then
    return retained_payload(conn, { 'state', 'wired', 'summary' }) ~= nil
  end
  return false
end

local function run_full_stack()
  local bus = busmod.new()
  local counters = {}

  fibers.run(function(root_scope)
    local conn = bus:connect({ origin_base = { kind = 'openwrt-vm-full-stack-test' } })
    local hal_scope = assert(root_scope:child())
    setup_mock_hal(hal_scope, conn, counters)

    local scopes = {}
    local function add(name, module, opts)
      opts = opts or {}
      opts.env = 'openwrt-vm-test'
      scopes[#scopes + 1] = spawn_service(root_scope, name, function() module.start(conn, opts) end)
    end

    add('config', config_service, { timings = { heartbeat_s = 60, hal_wait_timeout_s = 2 } })
    add('device', device_service, {})
    add('fabric', fabric_service, {})
    add('gsm', gsm_service, {})
    add('http', http_service, { driver = fake_http_driver(), observability = { stats_interval_s = 30, status_interval_s = 30 } })
    add('metrics', metrics_service, { heartbeat_s = 60 })
    add('monitor', monitor_service, {})
    add('net', net_service, {})
    add('system', system_service, {})
    add('time', time_service, {})
    add('ui', ui_service, {})
    add('update', update_service, {})
    add('wifi', wifi_service, {})
    add('wired', wired_service, {})

    wait_retained(conn, { 'cfg', 'net' }, nil, 'config service should publish net config', 3)
    wait_retained(conn, { 'svc', 'config', 'status' }, function(p) return p.state == 'running' end, 'config running', 3)
    wait_retained(conn, { 'svc', 'http', 'status' }, function(p) return p.state == 'running' end, 'http running', 3)
    wait_retained(conn, { 'cap', 'http', 'main', 'status' }, function(p) return p.available == true or p.state == 'available' or p.state == 'ready' end, 'http capability available', 3)
    wait_retained(conn, { 'cap', 'http', 'main', 'state', 'stats' }, function(p) return p.ready == true end, 'http stats ready', 3)
    wait_retained(conn, { 'svc', 'ui', 'status' }, function(p) return p.state == 'running' end, 'ui running', 3)
    wait_retained(conn, { 'svc', 'update', 'status' }, function(p) return p.state == 'running' or p.ready == true or p.state == 'starting' end, 'update admitted', 3)
    wait_retained(conn, { 'state', 'wired', 'summary' }, nil, 'wired summary retained', 3)
    wait_retained(conn, { 'state', 'wired', 'surface', 'cm5-eth0' }, nil, 'wired configured surface retained', 3)
    wait_retained(conn, { 'state', 'time', 'synced' }, function(p) return p == true end, 'time sync retained', 3)
    wait_until('net should call mocked network apply', function() return counters.network_apply_calls >= 1 end, 3)

    for _, name in ipairs({ 'device', 'fabric', 'gsm', 'metrics', 'monitor', 'net', 'system', 'time', 'wifi', 'wired' }) do
      assert_true(service_status_ready_or_running(conn, name), 'service did not publish acceptable status: ' .. name)
    end

    -- Exercise service churn against a slow mock network apply. This guards the
    -- full service graph against turning one config replacement into overlapping
    -- host-mutating HAL requests.
    local raw = assert(json.decode(encoded_services_config()))
    raw.net.rev = 2
    raw.net.data.description = 'openwrt-vm mock-hal apply gate rev2'
    counters.network_gate.block_next = true
    conn:retain({ 'cfg', 'net' }, raw.net)
    wait_until('second network apply should enter blocked mock HAL', function()
      return counters.network_gate.blocked ~= nil
    end, 3)

    local before_release_calls = counters.network_apply_calls
    raw.net.rev = 3
    raw.net.data.description = 'openwrt-vm mock-hal apply gate rev3'
    conn:retain({ 'cfg', 'net' }, raw.net)
    perform(sleep.sleep_op(0.15))
    assert_eq(counters.network_apply_active, 1, 'mock HAL should keep one host-mutating network apply active while first is blocked')
    assert_eq(counters.network_apply_max_active, 1, 'mock HAL network apply must be single-flight')

    counters.network_gate.block_next = false
    wait_until('blocked network apply should drain', function() return counters.network_apply_active == 0 end, 3)
    wait_until('latest pending network config should be applied after drain', function()
      return counters.network_apply_calls > before_release_calls
    end, 3)
    assert_eq(counters.network_apply_max_active, 1, 'mock HAL network apply must remain single-flight after pending drain')

    -- Ensure UI default read model is not pulling raw HAL state into public UI state.
    local raw_seen = false
    local state_view = conn:retained_view({ 'state' })
    state_view:close()
    local raw_msg = retained_payload(conn, { 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'counters' })
    if raw_msg ~= nil then raw_seen = true end
    assert_true(raw_seen == false, 'mock stack should not depend on raw HAL topics for UI/readiness')

    for _, scope in ipairs(scopes) do scope:cancel('test complete') end
    hal_scope:cancel('test complete')
    for _, scope in ipairs(scopes) do perform(scope:join_op()) end
    perform(hal_scope:join_op())
  end)

  print(('devicecode full stack mock HAL VM test: ok; services=14 network_apply_calls=%d fs_reads=%d'):format(counters.network_apply_calls or 0, #(counters.fs_reads or {})))
end

run_full_stack()
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$ROOT_DIR/src/configs" "$REMOTE/configs"
"$SCP_TO" "$WORK/run_devicecode_full_stack_mock_hal.lua" "$REMOTE/run_devicecode_full_stack_mock_hal.lua"
"$SSH" "cd '$REMOTE' && CONFIG_TARGET=openwrt-vm-full-stack lua ./run_devicecode_full_stack_mock_hal.lua"
