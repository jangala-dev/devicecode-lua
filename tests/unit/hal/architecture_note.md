# HAL lifecycle note for tests

This file is intentionally only a pointer. The current HAL architecture and
lifecycle rules are documented under `src/services/hal/architecture_note.md`.

Strict HAL resources use the standard vocabulary:

```text
terminate(reason)
  immediate, idempotent, non-yielding, finaliser-safe teardown

close_op()
  graceful resource close; may wait, flush, or complete protocol work

shutdown_op()
  graceful stop for active managers/components with an explicit stop policy
```

Legacy `stop` and `stop_op` remain only on the compatibility side of `hal.lua`
for older services and drivers.
