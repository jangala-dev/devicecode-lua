# Devicecode leak-probe VM harness

This harness runs the instrumented Devicecode tree inside the existing OpenWrt VM lane and collects leak-probe snapshots from a near-full service stack.

From `tests/integration/openwrt_vm`:

```sh
make run
make wait
make provision
make test-devicecode-leak-probe-full-stack
```

For a longer leak run:

```sh
DEVICECODE_LEAK_PROBE_DURATION_S=3600 \
DEVICECODE_LEAK_PROBE_INTERVAL=60 \
make test-devicecode-leak-probe-full-stack
```

The default service list is:

```text
monitor,hal,config,system,time,metrics,device,fabric,http,ui,update,net,wired,wifi,gsm
```

Override it with:

```sh
DEVICECODE_LEAK_PROBE_SERVICES=hal,config,device,update make test-devicecode-leak-probe-full-stack
```

## Modes

The default mode is `safe`:

```sh
DEVICECODE_LEAK_PROBE_MODE=safe make test-devicecode-leak-probe-full-stack
```

It uses the normal file-backed config service, but rewrites the HAL network provider to the in-memory fake provider before placing the config under `/data/devicecode/configs`. This lets the full service stack start in the VM without rewriting OpenWrt's management network.

To exercise the real OpenWrt network provider, use a disposable/reset VM disk and run:

```sh
DEVICECODE_LEAK_PROBE_MODE=openwrt make test-devicecode-leak-probe-full-stack
```

That mode uses the config file as supplied and may alter `/etc/config/network`, firewall, DHCP, mwan3 and shaping state inside the VM.

## Outputs

Host-side logs are copied under:

```text
tests/integration/openwrt_vm/work/leak-probe-<timestamp>/remote-logs/
```

Important files:

```text
probe.log       raw LEAK_PROBE snapshots
devicecode.log  stdout/stderr from the service stack
summary.txt     first and last snapshots plus selected counters
env.txt         interpreter, services, duration, mode and paths
```

Useful counters to compare over time:

```text
mem_kb
scope_children
scope_finalizers
scope_cancelled
exec_terminal_not_cleaned
scoped_work_live
scoped_work_body_not_reaped
request_owner_live
bus_retained
```

A rising `exec_terminal_not_cleaned` or `scope_finalizers` count alongside `mem_kb` is a strong sign of retained process/scope cleanup state. A rising `scope_children` or `scope_cancelled` count usually points at unjoined child scopes.
## HTTP transport dependencies

The full-stack leak probe starts `metrics`, `http` and `ui`, so the VM must have daurnimator/lua-http available. The Make target runs `scripts/ensure-devicecode-lua-http-deps` after provisioning. That helper installs native OpenWrt packages such as `cqueues`, `lpeg` and `luaossl` where available, and vendors the pure-Lua lua-http modules plus pure-Lua dependencies from GitHub into `/usr/share/lua`.

If an existing VM has already been provisioned, this helper still runs; `OPENWRT_PROVISION_FORCE=1` is not required just to add lua-http.


## Interpreter

The probe now defaults to `lua` in this VM so OpenWrt's packaged `cqueues` and `luaossl` modules can be used during the leak hunt. Override when deliberately comparing runtimes:

```sh
DEVICECODE_LEAK_PROBE_LUA=luajit make test-devicecode-leak-probe-full-stack
DEVICECODE_LEAK_PROBE_LUA=texlua make test-devicecode-leak-probe-full-stack
```

The dependency helper validates `lua-http` under the selected runtime; the default is now PUC Lua for VM leak-hunting fidelity.

## LuaJIT and HTTP-dependent services

The harness first tries to make the lua-http/cqueues stack usable under the selected runtime. The default runtime is PUC Lua because this OpenWrt VM can load the packaged `cqueues` and `luaossl` modules there. If dependency validation fails, the leak probe still runs the core service set:

```text
monitor,hal,config,system,time,device,fabric,update,net,wired,wifi,gsm
```

This excludes `metrics`, `http` and `ui`, which require lua-http/cqueues at
module load or service start.  To require the HTTP stack and fail instead of
falling back, run:

```sh
DEVICECODE_HTTP_DEPS_REQUIRED=1 make test-devicecode-leak-probe-full-stack
```

To force a particular service list, set `DEVICECODE_LEAK_PROBE_SERVICES`.

## v10: building compat53 inside OpenWrt

For a production-like LuaJIT run, the harness now assumes that OpenWrt is the
right build environment for the only non-trivial lua-http dependency not already
available as a suitable package: `compat53`.

The leak-probe target now runs `scripts/ensure-large-disk` before provisioning.
By default it grows the qcow2 virtual disk to:

```sh
OPENWRT_WORK_DISK_SIZE=2G
```

Override this if the VM needs more build space:

```sh
OPENWRT_WORK_DISK_SIZE=4G make test-devicecode-leak-probe-full-stack
```

Disable the disk growth step with:

```sh
OPENWRT_GROW_WORK_DISK=0 make test-devicecode-leak-probe-full-stack
```

`scripts/ensure-devicecode-lua-http-deps` now installs compiler/LuaRocks
packages where available and runs:

```sh
luarocks --tree=/usr --lua-version=5.1 install compat53
```

This builds compat53 inside the OpenWrt VM against the target runtime/libc,
then validates `compat53.string` and `compat53.utf8` under the selected Lua runtime.  Logs from
that build are left at:

```text
/tmp/devicecode-compat53-luarocks.log
```

If you deliberately want to use the old narrow fallback shims instead, set:

```sh
DEVICECODE_COMPAT53_USE_LUAROCKS=0 DEVICECODE_COMPAT53_REQUIRED=0 \
  make test-devicecode-leak-probe-full-stack
```


## v11: GPT fix during root filesystem growth

The OpenWrt combined EFI image uses GPT.  After the host qcow2 is enlarged,
the guest sees the larger `/dev/vda`, but the GPT backup header may still sit
at the old end of disk.  In that state, `parted -s resizepart` can fail with
`Unable to satisfy all constraints`, leaving `/` at about 100 MB.

The disk growth helper now runs a GPT fix step before resizing partition 2,
using `parted -f`/`--fix` where available and a pseudo-tty fallback for older
parted builds.  It also fails early if `/` still has less than:

```sh
OPENWRT_MIN_ROOT_FREE_KB=300000
```

Raise or lower this threshold if needed for your image:

```sh
OPENWRT_WORK_DISK_SIZE=4G OPENWRT_MIN_ROOT_FREE_KB=500000 \
  make test-devicecode-leak-probe-full-stack
```
