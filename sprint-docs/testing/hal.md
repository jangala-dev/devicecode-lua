# Testing HAL
## Challenges and considerations
HAL, by nature, interacts with hardware components that are outside of devicecode control. 
Hardware would be required to do a 100% faithful test of HAL but that creates a barrier to ease-of-testing.
To get around this a way to emulate hardware needs to be devised.

### Module Shim
If we aggregate common hardware interactions into their own modules (mmcli.lua, at.lua, qmi.lua) we can shim these modules to redirect from hardware interactions and into
software emulation of these interactions. For example consider the project structure:
```
devicecode-lua  /src    /services       /hal    /mmcli.lua
                                        hal.lua 
                /tests  /test_hal.lua
                        /services       /hal    /mmcli.lua
```
Here we have our production code under `src` and testing code under `tests`. 
Lua loads modules by looking though the directoriers defined in package.path, with directories eariler in the list being prioritised. 
The production code defines package.path as `"../?.lua;" .. package.path .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"` 
when executing from `devicecode-lua/src`. The production packages will only contain the real mmcli.lua implementation under src. 
We can shim our testing version of mmcli.lua by prepending `../tests/?.lua;` to package.path, 
causing the module loader to find the test version of mmcli.lua first while all other production modules (in this case hal.lua) will be loaded from production code, as expected.

### Fake Commands

The majority (if not all) hardware interactions take place via the command line with the fibers exec module. 
Each hardware interaction returns a Command object which has common functions to run and get back command output. 
Using our shim we can return fake commands which have the same functions but return results based on events that are 
defined via a simple file e.g.
```json
{
    [
        {"time" : 0.0, "output" : "No modems detected"},
        {"time" : 0.4, "output" : "(+) /org/freedesktop/ModemManager1/Modem/0 [QUALCOMM INCORPORATED] QUECTEL Mobile Broadband Module"},
        {"time" : 0.7, "output" : "(-) /org/freedesktop/ModemManager1/Modem/0 [QUALCOMM INCORPORATED] QUECTEL Mobile Broadband Module"},
        {"time" : 1.0, "output" : null}
    ]
}
```
