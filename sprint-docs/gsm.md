So, we've decided that `hal` will detect and identify the physical elements of the system and ferry this information to `gsm`:

### Elements received from HAL

Modems - `hal` will detect all the modems in the system
SimSets - `hal` will detect the Sim Sets available in the system

#### What are Sim Sets?

SimSets are sets of sim connectors that provide the possibility of sim connections. The elements of a SimSet can be the following:
  - a regular slot for a sim card (with or without sim detect capability)
  - an embedded esim, which can store multiple profiles

#### Relationships between modems and sim sets

Modems and SimSets have a many to many possible relationship. One Modem can be attached to multiple SimSets and one SimSet can be associated with multiple Modems.

#### Designs for our devices

##### Big Box v0.9

Has two Modems and two SimSets, arranged like this:

  - Modem 1 - Primary - associated with SimSet 1
  - Modem 2 - Secondary - associated with SimSet 2

  - SimSet 1 - single slot with no detect - associated with Modem 1
  - SimSet 2 - single slot with no detect - associated with Modem 2

##### Big Box v1
Has two modems and two SimSets, arranged like this:

  - Modem 1 - Primary - associated with SimSet 1 and SimSet 2
  - Modem 2 - Secondary - associated with SimSet 2

  - SimSet 1 - single eSim - associated with Modem 1
  - SimSet 2 - switcher with slots 1-4 (all for external sims with sim detect), and slot 5 (an eSim)  - associated with Modems 1 and 2

##### Get Box v1

Has one modem and one SimSet, arranged like this:

  - Modem 1 - Primary - associated with SimSet 1

  - SimSet 1 - single slot with no detect - associated with Modem 1

##### Get Box v1 + external Sim Switcher

Has one modem and one SimSet, arranged like this:

  - Modem 1 - Primary - associated with SimSet 1

  - SimSet 1 - switcher with slots 1-4 (all for external sims with sim detect) - associated with Modem 1


### Split of responsibility between `gsm` and `hal`

We want to ensure a clear boundary between `gsm` (and other services) and `hal`. Our initial implementation of these two services can help guide what this looks like!

So far, `hal` will provide information and control points for hardware. It will inform services should they try to do anything unsupported or illegal with hardware. For example, in the `gsm` world, `hal` will not permit (by *reply*ing to  a *request*) if `gsm` asks `hal` to:
- set a 4G modem to connect only to 5G networks
- connect a modem to a non-existent SimSet or non-existent slot in a SimSet
- connect a modem to a slot in a SimSet to which another modem is already connected
- etc.

This means that if Modem X is already connected to SimSet1-slot1, to connect Modem Y to this same SimSet slot, Modem X will first need to be disconnected from that SimSet slot. This will ensure that our intention, through our code will remain explicit.