#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-mwan-live-test"
WORK="$VM_DIR/work/mwan-live-test"

mkdir -p "$WORK"
cat > "$WORK/run_openwrt_mwan_live_weights.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local exec = require 'fibers.io.exec'
local provider_loader = require 'services.hal.backends.network.provider'
local perform = fibers.perform

local function fail(msg) error(msg, 2) end
local function contains(s, needle, msg)
  if type(s) ~= 'string' or not s:find(needle, 1, true) then
    fail((msg or ('missing text: ' .. tostring(needle))) .. '\n--- text ---\n' .. tostring(s))
  end
end
local function not_contains(s, needle, msg)
  if type(s) == 'string' and s:find(needle, 1, true) then
    fail(msg or ('unexpected text: ' .. tostring(needle)))
  end
end

local function assert_policy_probability(rules, iface, weight, remaining, expected, msg)
  local comment = string.format('\"%s %d %d\"', iface, weight, remaining)
  for line in tostring(rules or ''):gmatch('[^\r\n]+') do
    if line:find('mwan3_policy_balanced', 1, true) and line:find(comment, 1, true) then
      local prob = tonumber(line:match('%-%-probability%s+([%d%.]+)'))
      if not prob then
        fail((msg or 'missing probability') .. '\n--- line ---\n' .. line)
      end
      if math.abs(prob - expected) > 0.000001 then
        fail((msg or 'unexpected probability') .. ': got ' .. tostring(prob) .. ' expected ' .. tostring(expected) .. '\n--- line ---\n' .. line)
      end
      return
    end
  end
  fail((msg or 'missing policy rule') .. '\n--- rules ---\n' .. tostring(rules))
end

local function capture(...)
  local cmd = exec.command(...)
  local out, st, code, sig, err = perform(cmd:combined_output_op())
  if st == 'exited' and code == 0 then return out or '' end
  fail('command failed: ' .. table.concat({ ... }, ' ') .. ' ' .. tostring(err or out or st))
end

fibers.run(function()
  local before = capture('mwan3', 'status')
  contains(before, 'balanced:', 'balanced policy before live update')
  contains(before, 'wan (', 'wan present before live update')
  contains(before, 'wanb (', 'wanb present before live update')
  contains(before, 'wanc (', 'wanc present before live update')

  local provider = assert(provider_loader.new({ provider = 'openwrt', debounce_s = 0.01 }, {}))
  local result = perform(provider:apply_live_weights_op({
    policy = 'balanced',
    persist = false,
    members = {
      { interface = 'wan', metric = 1, weight = 50 },
      { interface = 'wanb', metric = 1, weight = 30 },
      { interface = 'wanc', metric = 1, weight = 20 },
    },
  }))
  if result.ok ~= true then fail(result.err or 'live weights failed') end

  local status = capture('mwan3', 'status')
  contains(status, 'balanced:', 'balanced policy after live update')
  contains(status, 'wan (50%)', 'new flows should use wan 50% share')
  contains(status, 'wanb (30%)', 'new flows should use wanb 30% share')
  contains(status, 'wanc (20%)', 'new flows should use wanc 20% share')

  local rules = capture('iptables-save', '-t', 'mangle')
  contains(rules, 'CONNMARK --restore-mark', 'existing connmarks should still be restored before policy')
  contains(rules, 'CONNMARK --save-mark', 'connmarks should still be saved')
  assert_policy_probability(rules, 'wan', 50, 100, 0.5, 'first conditional probability should be 50/100')
  assert_policy_probability(rules, 'wanb', 30, 50, 0.6, 'second conditional probability should be 30/50')
  contains(rules, '-A mwan3_policy_balanced -m mark --mark 0x0/0x3f00 -m comment --comment "wanc 20 20"', 'fall-through new-flow rule expected')
  not_contains(rules, 'conntrack -F', 'live update must not flush conntrack')

  local restore = perform(provider:apply_live_weights_op({
    policy = 'balanced',
    persist = false,
    members = {
      { interface = 'wan', metric = 1, weight = 1 },
      { interface = 'wanb', metric = 1, weight = 1 },
      { interface = 'wanc', metric = 1, weight = 1 },
    },
  }))
  if restore.ok ~= true then fail(restore.err or 'restore to equal weights failed') end
  provider:terminate('test complete')
end)

print('openwrt network provider MWAN live weights: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_mwan_live_weights.lua" "$REMOTE/run_openwrt_mwan_live_weights.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_mwan_live_weights.lua"
