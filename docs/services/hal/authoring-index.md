# HAL Authoring Guide Index

This index is the entry point for engineers implementing or extending HAL managers, drivers, capabilities, and backends.

## Read Order

1. [Architecture Standards](./architecture-standards.md)
2. [Implementation Cookbook](./implementation-cookbook.md)
3. [Interfaces Reference](./interfaces-reference.md)
4. [Backend Authoring Guide](./backend-authoring.md)

## Scope

- Primary example stack: modem
- Secondary/simple example stack: filesystem
- Intended for both onboarding engineers and maintainers
- Forward-looking guidance for adding new device classes

## Standards Policy

- Rules labeled MUST are compatibility and correctness requirements.
- Rules labeled SHOULD are recommended defaults.
- Rules labeled MAY are optional patterns.

## Canonical Source References

- `src/services/hal/managers/modemcard.lua`
- `src/services/hal/drivers/modem.lua`
- `src/services/hal/drivers/filesystem.lua`
- `src/services/hal/backends/modem/provider.lua`
- `src/services/hal/backends/modem/contract.lua`
- `src/services/hal/types/core.lua`
- `src/services/hal/types/capabilities.lua`
- `src/services/hal/types/capability_args.lua`
