# Testing

## Unit Testing

If we want to 100% unit test our code we will need to think about refactoring around local functions within modules that our
testing framework will not have scope of. If we want to test these functions we can either

- Add a global `_TEST` flag to our code that exports local functions at runtime, adds more internal complexity to every file that has local functions
- Export all functions and mark private functions with an underscore prefix
- Move local functions to either own file which will export them all

## Service Testing

### Hardware independent services

Service level testing will only require sending dummy signals through the central bus for simple services such as `Metrics` or `GSM`,
which has no module-level interactions with `HAL`. Some tests will be difficult as the reaction to a bus message may not be
exported outside of the service to be tested, therefore we cannot check validity of the reaction,
should we refactor the services to publish more state to the bus for this?

### Hardware dependant services

Hardware dependant services create an issue of emulating hardware events and interactions.

**Stateless Hardware Emulation**: Static emulation will allow us to run a command and always get back the same output independent of any other commands
or the wider state of the system. Statelessness is good for less complex integration tests and can be achieved by creating a set of shims, overwriting
Lua's package path and flushing Lua's package cache whenever a shim (or package dependant on a shim) needs to be loaded. This approach does become less appealing
if we wanted to chain together events in a responsive manner. Local state may be able to be held in our shim which could allow for a static loop of outputs each time a
command is called.

```lua
local tmodule = require "mod_folder.tmodule"
local tpack = require "pack_folder.tpack"

-- we expect non-shimed content
print("Unshimmed")
tmodule.run_test()
print(tpack.content())

-- changing path to priorities the loading of the shimmed module
package.path = "./harness/?.lua;" .. package.path

-- unload both modules
package.loaded["pack_folder.tpack"] = nil
package.loaded["mod_folder.tmodule"] = nil

local tmodule = require "mod_folder.tmodule"
local tpack = require "pack_folder.tpack"

-- both now show overriden content
print("\nBoth uncached")
tmodule.run_test()
print(tpack.content())
```

```bash
root
    main.lua
    /mod_folder
                  tmodule.lua
    /pack_folder
                  tpack.lua
    /harness
                  /pack_folder
                                tpack.lua (shim)
```

**Stateful Hardware Emulation**: This is significantly more complex and I severely doubt it would get done before the MVP deadline, if it did I still expect the
time spent developing it to be far too much when it could have been spent on functional code. Stateful emulation would allow us to create as faithful a model of different
hardware as possible, this means a command send in one module could impact the result of a command in another. I have no idea how to keep state of hardware between modules
apart from maybe maintaining ctx be passed as an argument for all commands and then we can sneak state in there.
