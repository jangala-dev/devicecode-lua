So, we've decided that hal.lua will detect and identify the physical elements of the system:

Modems - HAL will detect all the modems in the system
Sim Sets - HAL will detect the Sim Sets available in the system

#### What are Sim Sets?

Sim Sets are sets of sim connectors that provide the possibility of sim connections. The elements of a Sim Set can be the following:
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
Has two <odems and two SimSets, arranged like this:

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


