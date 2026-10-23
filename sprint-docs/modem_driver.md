# Modem Driver Structure

Before a driver can be used it must be initialised with an integer address
``` lua
local driver = modem_driver.new(context.with_cancel(ctx), <address>)
local err = driver:init()
```

The modem driver is made up of a set of functions for direct interaction such as
`init` and `get` but also has `command_manager` and `state_monitor` functions
which are created in a long running fiber (both of which must be created externally).
``` lua
service.spawn_fiber('State Monitor - '..imei, bus_conn, ctx, function ()
    driver:monitor_manager(bus_conn)
end)

service.spawn_fiber('Command Manger - '..imei, bus_conn, ctx, function ()
    driver:command_manager()
end)
```

The current available commands are:
- enable
- disable
- restart
- connect
- disconnect
- inhibit
- set_modes (typed preferred generation and allowed generation list)

The mode fields `supported_modes` and `current_modes` are available through the
driver's `get` operation. Supported modes are complete `{preferred, allowed}`
combinations rather than an independent list of generations. `set_modes` accepts
`capability_args.new.ModemSetModesOpts(preferred, allowed)`; a concrete preferred
generation must also appear in the nonempty allowed list. `none` means no explicit
preference. Successful writes invalidate mode, network, signal, and traffic caches.

Commands are sent over a command queue held by the driver. A command is a table of:
```
{
  command = <command e.g. "enable">,
  args = <list of args>,
  return_channel = <channel>
}
```
To execute a command it would look like
``` lua
local driver_q = driver.command_q
local cmd = {
  command = "enable",
  args = nil,
  return_channel = channel.new()
}

driver_q:put(cmd)
local result = return_channel:get()
```

