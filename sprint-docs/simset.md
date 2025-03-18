### Simsets
## Description
Simsets are a group of sims, used to describe modem <--> sim potential relationships.
The simset will be a component under `HAL`, therefore there will be a simset manager.

## Simset Manager
The simset Manager, being a component of HAL will have a manager and detection fiber.

### Manager Fiber
The manager fiber will publish apply configs to simsets and publish them to HAL to be exposed as (capabilities or devices?????).

### Detection Fiber
The detection fiber will lookup simsets defined in configs and push them to the manager

## Bus Structure
Follows the pattern
`hal/device/simset/<simset_index>/<sim_index>`
```
hal /device /simset /1  /1
                        /2
                        /3
                    /2  /1
                        /2
```
## Sim switching
In order to sim switch three things must be known
- the modem that is switching
- the current sim assigned to the modem
- the new sim to be assigned to the modem

The question is, does the modem driver or a sim driver handle this case?
A sim could know which modem it is assigned to but must then contact the new sim
to do handover. The modem driver would drop the current sim and switch to the new one,
it needs to know if the sim is accesable or not.

Ok heres some modem-as-host sim switching psuedocode
- GSM publish to /hal/capability/modem/1/control/assign_sim, args(sim_set, sim_index)
- Modem driver checks that sim_set is accessible, if not then return error
- Modem driver


# Notes

The simset module is mainly focusing on the gpio sim switching NOT sim operations such as unlock attempts etc. All it must do is hold possible conenction and perform siwtches.
It would still be good if the simset module could provide some functionality of what slots have sims in, but this may only be possible (and only needed) with bb1.
Each modem can have a config for default sim to connect to, which is given to GSM, primary has slot 1, secondary has slot 2 and everything else is nothing unless configured by the user
