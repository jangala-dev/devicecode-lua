#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="${DEVICECODE_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)}"

if [ -d "$ROOT_DIR/src" ]; then
	DEFAULT_APP_DIR="$ROOT_DIR/src"
	DEFAULT_CONFIG_DIR="$ROOT_DIR/src/configs"
else
	DEFAULT_APP_DIR="$ROOT_DIR"
	DEFAULT_CONFIG_DIR="$ROOT_DIR/configs"
fi

SERVICES_FILE="${DEVICECODE_ALL_SERVICES_FILE:-$SCRIPT_DIR/all_services}"
MANAGERS_FILE="${DEVICECODE_ALL_MANAGERS_FILE:-$SCRIPT_DIR/all_managers}"
CONFIG_TARGET="${CONFIG_TARGET:-bigbox-v1-cm-2}"
APP_DIR="${DEVICECODE_APP_DIR:-$DEFAULT_APP_DIR}"
CONFIG_DIR="${DEVICECODE_CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
APP_DIR="${APP_DIR%/}"
CONFIG_DIR="${CONFIG_DIR%/}"
CONFIG_FILE="$CONFIG_DIR/$CONFIG_TARGET.json"
LUA_BIN="${DEVICECODE_LUA_BIN:-luajit}"
RUN_SECONDS="${DEVICECODE_RUN_SECONDS:-120}"
LOG_DIR="${DEVICECODE_LOG_DIR:-/tmp/devicecode-per-component-dropped-$(date -u +%Y%m%dT%H%M%SZ)}"

if [ ! -f "$CONFIG_FILE" ]; then
	for candidate in \
		"$ROOT_DIR/configs/$CONFIG_TARGET.json" \
		"$ROOT_DIR/src/configs/$CONFIG_TARGET.json"
	do
		if [ -f "$candidate" ]; then
			CONFIG_FILE="$candidate"
			CONFIG_DIR="$(dirname -- "$candidate")"
			break
		fi
	done
fi

fail() {
	printf '%s\n' "[per-component] FAIL: $*" >&2
	exit 1
}

need_file() {
	[ -f "$1" ] || fail "missing file: $1"
}

need_file "$SERVICES_FILE"
need_file "$MANAGERS_FILE"
need_file "$CONFIG_FILE"
need_file "$APP_DIR/main.lua"
command -v "$LUA_BIN" >/dev/null 2>&1 || fail "Lua interpreter not found: $LUA_BIN"

printf '%s\n' "[per-component] root=$ROOT_DIR app_dir=$APP_DIR config_dir=$CONFIG_DIR config_target=$CONFIG_TARGET"

mkdir -p "$LOG_DIR"

CONFIG_BACKUP="$LOG_DIR/$(basename "$CONFIG_FILE").original"
cp "$CONFIG_FILE" "$CONFIG_BACKUP"

restore_config() {
	cp "$CONFIG_BACKUP" "$CONFIG_FILE"
}

trap restore_config EXIT
trap 'restore_config; exit 130' INT
trap 'restore_config; exit 143' TERM

csv_from_file_except() {
	drop="${1:-}"
	csv=''
	while IFS= read -r name || [ -n "$name" ]; do
		case "$name" in
			''|'#'*) continue ;;
		esac
		[ "$name" = "$drop" ] && continue
		if [ -z "$csv" ]; then
			csv="$name"
		else
			csv="$csv,$name"
		fi
	done < "$SERVICES_FILE"
	printf '%s\n' "$csv"
}

write_config_without_manager() {
	drop="$1"
	"$LUA_BIN" - "$CONFIG_BACKUP" "$CONFIG_FILE" "$drop" <<'LUA'
local ok_safe, cjson = pcall(require, 'cjson.safe')
if not ok_safe then
	cjson = require 'cjson'
end

local src, dst, drop = arg[1], arg[2], arg[3]

local function read_file(path)
	local f, err = io.open(path, 'rb')
	if not f then error(err, 0) end
	local text = f:read('*a')
	f:close()
	return text
end

local function write_file(path, text)
	local f, err = io.open(path, 'wb')
	if not f then error(err, 0) end
	f:write(text)
	f:close()
end

local decoded, err = cjson.decode(read_file(src))
if not decoded then
	error('failed to decode ' .. src .. ': ' .. tostring(err), 0)
end

local hal_data = decoded.hal and decoded.hal.data
if type(hal_data) ~= 'table' then
	error('config has no hal.data table: ' .. src, 0)
end
if hal_data[drop] == nil then
	error('manager not present in hal.data: ' .. tostring(drop), 0)
end

hal_data[drop] = nil
write_file(dst, assert(cjson.encode(decoded)))
LUA
}

sample_memory() {
	label="$1"
	pid="$2"
	out="$3"
	if ps -o pid= -p "$pid" >/dev/null 2>&1; then
		sampler_mode='ps'
	else
		sampler_mode='procfs'
	fi
	i=0
	while kill -0 "$pid" 2>/dev/null; do
		{
			printf 'sample=%s time=%s pid=%s\n' "$i" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pid"
			if [ "$sampler_mode" = 'ps' ]; then
				ps -o pid,ppid,rss,vsz,comm,args -p "$pid" 2>/dev/null || true
			elif [ -r "/proc/$pid/status" ]; then
				awk -v pid="$pid" '
					BEGIN { ppid="?"; vmrss="?"; vmsize="?"; name="?" }
					/^Name:[[:space:]]+/ { name=$2 }
					/^PPid:[[:space:]]+/ { ppid=$2 }
					/^VmRSS:[[:space:]]+/ { vmrss=$2 " " $3 }
					/^VmSize:[[:space:]]+/ { vmsize=$2 " " $3 }
					END {
						printf "pid=%s ppid=%s rss=%s vsz=%s comm=%s\n", pid, ppid, vmrss, vmsize, name
					}
				' "/proc/$pid/status"
			else
				printf '%s\n' 'memory unavailable: ps format unsupported and /proc/<pid>/status not readable'
			fi
			printf '\n'
		} >> "$out"
		i=$((i + 1))
		sleep "${DEVICECODE_SAMPLE_SECONDS:-5}"
	done
	printf '%s\n' "[per-component] memory sampler stopped for $label" >> "$out"
}

run_variant() {
	kind="$1"
	name="$2"
	services="$3"
	label="$kind-$name"
	case "$label" in
		*/*) label="$(printf '%s\n' "$label" | tr '/' '_')" ;;
	esac

	restore_config
	if [ "$kind" = "drop-manager" ]; then
		write_config_without_manager "$name"
	fi

	run_dir="$LOG_DIR/$label"
	mkdir -p "$run_dir"
	printf '%s\n' "$services" > "$run_dir/services.csv"
	cp "$CONFIG_FILE" "$run_dir/$CONFIG_TARGET.json"

	printf '%s\n' "[per-component] starting $label for ${RUN_SECONDS}s"
	(
		cd "$APP_DIR"
		DEVICECODE_ENV=dev \
		DEVICECODE_SERVICES="$services" \
		DEVICECODE_CONFIG_DIR="$CONFIG_DIR" \
		CONFIG_TARGET="$CONFIG_TARGET" \
		"$LUA_BIN" main.lua
	) > "$run_dir/devicecode.log" 2>&1 &
	pid="$!"

	sample_memory "$label" "$pid" "$run_dir/memory.log" &
	sampler_pid="$!"

	elapsed=0
	while [ "$elapsed" -lt "$RUN_SECONDS" ] && kill -0 "$pid" 2>/dev/null; do
		sleep 1
		elapsed=$((elapsed + 1))
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
	fi
	wait "$pid" 2>/dev/null || true

	if kill -0 "$sampler_pid" 2>/dev/null; then
		kill "$sampler_pid" 2>/dev/null || true
	fi
	wait "$sampler_pid" 2>/dev/null || true

	restore_config
	printf '%s\n' "[per-component] finished $label; logs: $run_dir"
}

all_services="$(csv_from_file_except '')"
[ -n "$all_services" ] || fail "no services listed in $SERVICES_FILE"

run_variant all enabled "$all_services"

while IFS= read -r service || [ -n "$service" ]; do
	case "$service" in
		''|'#'*) continue ;;
	esac
	run_variant drop-service "$service" "$(csv_from_file_except "$service")"
done < "$SERVICES_FILE"

while IFS= read -r manager || [ -n "$manager" ]; do
	case "$manager" in
		''|'#'*) continue ;;
	esac
	run_variant drop-manager "$manager" "$all_services"
done < "$MANAGERS_FILE"

printf '%s\n' "[per-component] complete; logs: $LOG_DIR"
