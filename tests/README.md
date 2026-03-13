This folder will contain tests for `devicecode`.

Deterministic async test helpers live in `tests/test_utils/`.

- `virtual_time.lua` installs a test-controlled monotonic and realtime clock for fibers-based tests.
- `time_harness.lua` provides general op helpers:
	- `try_op_now(op_or_factory)` for non-blocking op probes,
	- `wait_op_ticks(op_or_factory, { max_ticks = ... })` for bounded scheduler-turn waits,
	- `wait_op_within(clock, timeout_s, op_or_factory, ...)` for virtual-time bounded waits,
	plus compatibility helpers for metrics subscriptions.

For fibers service tests, prefer advancing virtual time and flushing a bounded number of scheduler turns over wall-clock sleeps. This keeps tests focused on logic and avoids timing-dependent flakes across different environments.
