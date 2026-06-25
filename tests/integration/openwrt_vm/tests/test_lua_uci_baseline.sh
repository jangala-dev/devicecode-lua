#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
SSH="$VM_DIR/scripts/ssh"

"$SSH" 'command -v lua >/dev/null'
"$SSH" 'test -f /usr/lib/lua/uci.so -o -f /usr/lib/lua/5.1/uci.so -o -f /usr/lib/lua/5.4/uci.so'

"$SSH" '
	set -eu
	TMP="$(mktemp -d /tmp/dc-uci.XXXXXX)"
	trap "rm -rf \"$TMP\"" EXIT
	mkdir -p "$TMP/conf" "$TMP/save"
	printf "# devicecode UCI VM test\n" > "$TMP/conf/dcuci"
	CONF="$TMP/conf" SAVE="$TMP/save" lua - <<'"'"'LUA'"'"'
local uci = require "uci"
local conf = assert(os.getenv("CONF"))
local save = assert(os.getenv("SAVE"))
local c = assert(uci.cursor(conf, save))
if type(c.load) == "function" then pcall(function() c:load("dcuci") end) end

assert(c:set("dcuci", "named", "example"))
assert(c:set("dcuci", "named", "scalar", "value with spaces"))
assert(c:set("dcuci", "named", "enabled", "1"))
assert(c:set("dcuci", "named", "listopt", { "one", "two" }))

local anon = assert(c:add("dcuci", "thing"))
assert(type(anon) == "string" and #anon > 0, "anonymous add returned no name")
assert(c:set("dcuci", anon, "name", "anonymous"))
if type(c.reorder) == "function" then assert(c:reorder("dcuci", anon, 0)) end

local seen = false
assert(c:foreach("dcuci", "thing", function(s)
  if s[".name"] == anon then seen = true end
end))
assert(seen, "foreach did not see anonymous section")

assert(c:delete("dcuci", "named", "scalar"))
assert(c:commit("dcuci"))

local c2 = assert(uci.cursor(conf, save))
local scalar = c2:get("dcuci", "named", "scalar")
assert(scalar == nil, "deleted scalar should be absent")
assert(c2:get("dcuci", "named", "enabled") == "1")
local list = c2:get("dcuci", "named", "listopt")
assert(type(list) == "table", "listopt should be a Lua table")
assert(list[1] == "one" and list[2] == "two", "listopt contents mismatch")
LUA
'

echo "openwrt lua UCI baseline: ok"
