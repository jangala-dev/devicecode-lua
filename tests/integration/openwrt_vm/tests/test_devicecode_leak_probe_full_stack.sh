#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
SCP_FROM="$VM_DIR/scripts/scp-from"

# Duration and sampling are deliberately configurable.  The default is long
# enough to prove that the full stack starts and emits several probe samples,
# but short enough for normal VM iteration.  For leak hunting, run with e.g.
# DEVICECODE_LEAK_PROBE_DURATION_S=3600 DEVICECODE_LEAK_PROBE_INTERVAL=60.
DURATION_S="${DEVICECODE_LEAK_PROBE_DURATION_S:-300}"
INTERVAL_S="${DEVICECODE_LEAK_PROBE_INTERVAL:-30}"
CONFIG_TARGET="${DEVICECODE_LEAK_PROBE_CONFIG_TARGET:-bigbox-v1-cm-2}"
MODE="${DEVICECODE_LEAK_PROBE_MODE:-safe}"
HAL_MANAGERS="${DEVICECODE_LEAK_PROBE_HAL_MANAGERS:-}"
HAL_EXCLUDE_MANAGERS="${DEVICECODE_LEAK_PROBE_HAL_EXCLUDE_MANAGERS:-}"
REMOTE="${DEVICECODE_LEAK_PROBE_REMOTE:-/tmp/devicecode-leak-probe-tree}"
REMOTE_LOG_DIR="${DEVICECODE_LEAK_PROBE_REMOTE_LOG_DIR:-/tmp/devicecode-leak-probe}"
# FULL_SERVICES="monitor,hal,config,system,time,metrics,device,fabric,http,ui,update,net,wired,wifi,gsm"
FULL_SERVICES="monitor,hal,config,system,time,metrics,device,fabric,http,ui,update,net,wired,gsm"
CORE_SERVICES="monitor,hal,config,system,time,device,fabric,update,net,wired,wifi,gsm"
if [ -n "${DEVICECODE_LEAK_PROBE_SERVICES+x}" ]; then
	SERVICES="$DEVICECODE_LEAK_PROBE_SERVICES"
else
	HTTP_STATUS_FILE="${DEVICECODE_HTTP_DEPS_STATUS_FILE:-/tmp/devicecode-lua-http-deps.status}"
	if "$SSH" "test -f '$HTTP_STATUS_FILE' && grep -q '^available' '$HTTP_STATUS_FILE'" >/dev/null 2>&1; then
		SERVICES="$FULL_SERVICES"
	else
		SERVICES="$CORE_SERVICES"
		printf '%s\n' "[leak-probe] lua-http/cqueues not available under selected Lua runtime; using core service set without metrics,http,ui" >&2
	fi
fi
LUA_BIN="${DEVICECODE_LEAK_PROBE_LUA:-lua}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="${DEVICECODE_LEAK_PROBE_WORK_DIR:-$VM_DIR/work/leak-probe-$RUN_ID}"

fail() {
	printf '%s\n' "[leak-probe] FAIL: $*" >&2
	exit 1
}

mkdir -p "$WORK"

cat > "$WORK/run_devicecode_leak_probe.sh" <<'REMOTE_SH'
#!/usr/bin/env sh
set -eu

remote_root="$1"
duration_s="$2"
interval_s="$3"
services="$4"
config_target="$5"
mode="$6"
log_dir="$7"
lua_bin_arg="${8:-}"
hal_managers_arg="${9:-}"
hal_exclude_managers_arg="${10:-}"

fail() {
	echo "[leak-probe/vm] FAIL: $*" >&2
	if [ -f "$log_dir/devicecode.log" ]; then
		echo "--- devicecode.log tail ---" >&2
		tail -n 120 "$log_dir/devicecode.log" >&2 || true
	fi
	if [ -f "$log_dir/probe.log" ]; then
		echo "--- probe.log tail ---" >&2
		tail -n 80 "$log_dir/probe.log" >&2 || true
	fi
	exit 1
}

choose_lua() {
	if [ -n "$lua_bin_arg" ]; then
		command -v "$lua_bin_arg" >/dev/null 2>&1 || fail "requested Lua interpreter not found: $lua_bin_arg"
		printf '%s\n' "$lua_bin_arg"
		return
	fi
	# For the leak hunt this VM defaults to PUC Lua, because the OpenWrt
	# cqueues/luaossl packages load cleanly there.  Set
	# DEVICECODE_LEAK_PROBE_LUA=luajit when deliberately comparing runtimes.
	if command -v lua >/dev/null 2>&1; then printf '%s\n' lua; return; fi
	if command -v luajit >/dev/null 2>&1; then printf '%s\n' luajit; return; fi
	if command -v texlua >/dev/null 2>&1; then printf '%s\n' texlua; return; fi
	fail 'no lua, luajit or texlua interpreter found in VM'
}

lua_bin="$(choose_lua)"

rm -rf "$log_dir"
mkdir -p "$log_dir" \
	/data/devicecode/configs \
	/data/configs \
	/data/devicecode/artifacts/import \
	/data/devicecode/control/update \
	/tmp/devicecode-state \
	/tmp/devicecode-artifacts

cat > /data/configs/mainflux.cfg <<'JSON'
{"networks":{"networks":[{"ssid":"Devicecode VM","name":"jan","encryption":"psk2","password":"devicecode-vm-test"}]}}
JSON

# Build the config file consumed by the real config service.  In safe mode we
# keep the default product config shape but avoid destructive OpenWrt network
# apply work by using the in-memory network provider.  Set
# DEVICECODE_LEAK_PROBE_MODE=openwrt to exercise the real OpenWrt provider.
cd "$remote_root/src"
"$lua_bin" - "$config_target" "$mode" "$hal_managers_arg" "$hal_exclude_managers_arg" "$log_dir" <<'LUA'
local cjson = require 'cjson.safe'
local target, mode, hal_managers, hal_exclude_managers, log_dir = arg[1], arg[2], arg[3], arg[4], arg[5]
local function read(path)
  local f, err = io.open(path, 'rb')
  if not f then error(err, 0) end
  local s = f:read('*a')
  f:close()
  return s
end
local function write(path, s)
  local f, err = io.open(path, 'wb')
  if not f then error(err, 0) end
  f:write(s)
  f:close()
end
local src = './configs/' .. target .. '.json'
local doc, err = cjson.decode(read(src))
if not doc then error('decode ' .. src .. ': ' .. tostring(err), 0) end

local function split_csv(s)
  local out = {}
  if type(s) ~= 'string' or s == '' then return out end
  for item in s:gmatch('[^,]+') do
    item = item:gsub('^%s+', ''):gsub('%s+$', '')
    if item ~= '' then out[#out + 1] = item end
  end
  return out
end

local function set_from_list(list)
  local set = {}
  for i = 1, #list do set[list[i]] = true end
  return set
end

local function filter_hal_managers(doc, include_csv, exclude_csv)
  local hal = doc.hal and doc.hal.data
  if type(hal) ~= 'table' then return end

  local include = set_from_list(split_csv(include_csv))
  local exclude = set_from_list(split_csv(exclude_csv))
  local has_include = next(include) ~= nil

  if not has_include and next(exclude) == nil then return end

  local preserved = { schema = hal.schema }
  for name, value in pairs(hal) do
    if name ~= 'schema' then
      local keep = true
      if has_include then keep = include[name] == true end
      if exclude[name] then keep = false end
      if keep then preserved[name] = value end
    end
  end
  doc.hal.data = preserved
end

local hal_filter_active = (type(hal_managers) == 'string' and hal_managers ~= '')
  or (type(hal_exclude_managers) == 'string' and hal_exclude_managers ~= '')

filter_hal_managers(doc, hal_managers, hal_exclude_managers)

if mode == 'safe' then
  -- In unfiltered safe-mode runs we preserve the historical behaviour and add
  -- a fake network provider to avoid destructive OpenWrt network apply work.
  -- When HAL manager include/exclude filters are active, do not reintroduce
  -- network if the filter removed it; this keeps HAL-manager bisection honest.
  if not hal_filter_active then
    doc.hal = doc.hal or { rev = 1, data = {} }
    doc.hal.data = doc.hal.data or {}
  end
  if doc.hal and doc.hal.data and doc.hal.data.network ~= nil then
    doc.hal.data.network = doc.hal.data.network or {}
    doc.hal.data.network.provider = 'fake'
    doc.hal.data.network.backend = 'fake'
  end

  -- Keep HTTP/UI alive in the VM but avoid accidental port conflicts when a
  -- developer is also using port 8080 in another manual process.
  if doc.ui and doc.ui.data and doc.ui.data.http then
    doc.ui.data.http.host = doc.ui.data.http.host or '127.0.0.1'
    doc.ui.data.http.port = tonumber(os.getenv('DEVICECODE_LEAK_PROBE_UI_PORT') or '') or doc.ui.data.http.port or 8080
  end
elseif mode == 'openwrt' then
  -- Use the config as supplied.  This may modify the VM's OpenWrt network
  -- configuration.  Prefer a disposable/reset VM disk for this mode.
else
  error('unknown DEVICECODE_LEAK_PROBE_MODE: ' .. tostring(mode), 0)
end

local function active_hal_manager_csv(doc)
  local hal = doc.hal and doc.hal.data
  if type(hal) ~= 'table' then return '' end
  local names = {}
  for name, _ in pairs(hal) do
    if name ~= 'schema' then names[#names + 1] = name end
  end
  table.sort(names)
  return table.concat(names, ',')
end

write('/data/devicecode/configs/' .. target .. '.json', assert(cjson.encode(doc)))

if type(log_dir) == 'string' and log_dir ~= '' then
  write(log_dir .. '/hal-managers.env',
    'hal_managers_include=' .. tostring(hal_managers or '') .. '\n' ..
    'hal_managers_exclude=' .. tostring(hal_exclude_managers or '') .. '\n' ..
    'hal_managers_active=' .. active_hal_manager_csv(doc) .. '\n')
end
LUA

hal_env="$(cat "$log_dir/hal-managers.env" 2>/dev/null || {
	printf 'hal_managers_include=%s\n' "$hal_managers_arg"
	printf 'hal_managers_exclude=%s\n' "$hal_exclude_managers_arg"
	printf 'hal_managers_active=\n'
})"

cat > "$log_dir/env.txt" <<EOF
lua_bin=$lua_bin
duration_s=$duration_s
interval_s=$interval_s
services=$services
$hal_env
config_target=$config_target
mode=$mode
remote_root=$remote_root
update_memory_job_store=${DEVICECODE_LEAK_PROBE_UPDATE_MEMORY_JOB_STORE:-1}
EOF

export DEVICECODE_ENV=dev
export DEVICECODE_SERVICES="$services"
export DEVICECODE_CONFIG_DIR=/data/devicecode/configs
export DEVICECODE_STATE_DIR=/tmp/devicecode-state
export CONFIG_TARGET="$config_target"
export CLOUD_URL="${CLOUD_URL:-http://127.0.0.1:9/metrics}"
export SWITCH_USERNAME="${SWITCH_USERNAME:-vm}"
export SWITCH_PASSWORD="${SWITCH_PASSWORD:-vm}"
export DEVICECODE_LEAK_PROBE=1
export DEVICECODE_LEAK_PROBE_INTERVAL="$interval_s"
export DEVICECODE_LEAK_PROBE_FILE="$log_dir/probe.log"
export DEVICECODE_LEAK_PROBE_BUS="${DEVICECODE_LEAK_PROBE_BUS:-1}"
# The OpenWrt VM's HAL control-store provider can still be applying config when
# update starts its durable job-runtime load.  For leak hunting we default update
# to its in-memory job store so the full service stack can reach steady state.
# Set DEVICECODE_LEAK_PROBE_UPDATE_MEMORY_JOB_STORE=0 to exercise the real
# control-store-backed path.
export DEVICECODE_LEAK_PROBE_UPDATE_MEMORY_JOB_STORE="${DEVICECODE_LEAK_PROBE_UPDATE_MEMORY_JOB_STORE:-1}"
# Keep vendored and OpenWrt Lua module search paths stable across LuaJIT,
# PUC Lua and texlua package.path differences.  The trailing ;; preserves the
# interpreter defaults.
export LUA_PATH="./?.lua;./?/init.lua;../vendor/lua-trie/src/?.lua;../vendor/lua-trie/src/?/init.lua;../vendor/lua-bus/src/?.lua;../vendor/lua-bus/src/?/init.lua;../vendor/lua-fibers/src/?.lua;../vendor/lua-fibers/src/?/init.lua;/usr/share/lua/?.lua;/usr/share/lua/?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;/usr/lib/lua/5.1/?.lua;/usr/lib/lua/5.1/?/init.lua;;"
export LUA_CPATH="./?.so;./?/init.so;/usr/lib/lua/?.so;/usr/lib/lua/?/init.so;/usr/lib/lua/5.1/?.so;/usr/lib/lua/5.1/?/init.so;/usr/lib/lua/loadall.so;;"

(
	cd "$remote_root/src"
	exec "$lua_bin" ./main.lua
) > "$log_dir/devicecode.log" 2>&1 &
pid="$!"
echo "$pid" > "$log_dir/devicecode.pid"

start="$(date +%s)"
early=0
while :; do
	now="$(date +%s)"
	elapsed=$((now - start))
	if ! kill -0 "$pid" 2>/dev/null; then
		early=1
		break
	fi
	if [ "$elapsed" -ge "$duration_s" ]; then
		break
	fi
	sleep 5
 done

if [ "$early" -eq 1 ]; then
	wait "$pid" || rc="$?"
	echo "exit_code=${rc:-0}" > "$log_dir/exit.txt"
	fail "devicecode exited before ${duration_s}s"
fi

kill "$pid" 2>/dev/null || true
sleep 2
if kill -0 "$pid" 2>/dev/null; then
	kill -9 "$pid" 2>/dev/null || true
fi
wait "$pid" >/dev/null 2>&1 || true

echo "completed_duration_s=$duration_s" > "$log_dir/exit.txt"

[ -s "$log_dir/probe.log" ] || fail 'probe log was not created or is empty'
grep -q '^LEAK_PROBE ' "$log_dir/probe.log" || fail 'probe log contains no LEAK_PROBE main snapshots'

# Emit a small VM-side summary for the host log.
{
	echo '--- leak probe env ---'
	cat "$log_dir/env.txt"
	echo '--- first probe snapshot ---'
	grep '^LEAK_PROBE ' "$log_dir/probe.log" | head -n 1 || true
	echo '--- last probe snapshot ---'
	grep '^LEAK_PROBE ' "$log_dir/probe.log" | tail -n 1 || true
	echo '--- highest-risk counters from last snapshot ---'
	last="$(grep '^LEAK_PROBE ' "$log_dir/probe.log" | tail -n 1 || true)"
	for key in mem_kb scope_live scope_children scope_finalizers scope_cancelled exec_live exec_terminal_not_cleaned scoped_work_live scoped_work_body_not_reaped request_owner_live bus_retained; do
		printf '%s=' "$key"
		printf '%s\n' "$last" | tr ' ' '\n' | awk -F= -v k="$key" '$1==k {print $2; found=1} END {if (!found) print ""}'
	done
	echo '--- last exec samples ---'
	grep '^LEAK_PROBE_EXEC_SAMPLES ' "$log_dir/probe.log" | tail -n 1 || true
	echo '--- last scoped-work kinds ---'
	grep '^LEAK_PROBE_SCOPED_WORK_KINDS ' "$log_dir/probe.log" | tail -n 1 || true
} > "$log_dir/summary.txt"

cat "$log_dir/summary.txt"
REMOTE_SH
chmod +x "$WORK/run_devicecode_leak_probe.sh"

printf '%s\n' "[leak-probe] syncing instrumented tree to VM: $REMOTE"
"$SSH" "rm -rf '$REMOTE' '$REMOTE_LOG_DIR'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_devicecode_leak_probe.sh" "$REMOTE/run_devicecode_leak_probe.sh"

printf '%s\n' "[leak-probe] running full-stack probe for ${DURATION_S}s, interval ${INTERVAL_S}s, mode ${MODE}"
if ! "$SSH" "sh '$REMOTE/run_devicecode_leak_probe.sh' '$REMOTE' '$DURATION_S' '$INTERVAL_S' '$SERVICES' '$CONFIG_TARGET' '$MODE' '$REMOTE_LOG_DIR' '$LUA_BIN' '$HAL_MANAGERS' '$HAL_EXCLUDE_MANAGERS'"; then
	mkdir -p "$WORK/remote-logs" || true
	"$SCP_FROM" "$REMOTE_LOG_DIR" "$WORK/remote-logs" >/dev/null 2>&1 || true
	fail "remote leak probe failed; logs, if collected, are under $WORK/remote-logs"
fi

mkdir -p "$WORK"
"$SCP_FROM" "$REMOTE_LOG_DIR" "$WORK/remote-logs"

printf '%s\n' "[leak-probe] collected logs: $WORK/remote-logs"
if [ -f "$WORK/remote-logs/summary.txt" ]; then
	cat "$WORK/remote-logs/summary.txt"
fi
