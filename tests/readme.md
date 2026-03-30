# Tests

This directory contains the automated test suite for `devicecode-lua`.

The suite is organised to give fast feedback on pure logic, then broader confidence in service composition, and later platform confidence on OpenWrt and real hardware.

## Test design

The tests follow a layered model.

### Unit tests

Unit tests cover small modules in isolation. They are intended to be:

- fast
- deterministic
- side-effect free where possible
- easy to diagnose when they fail

Typical unit subjects include:

- codecs and state helpers
- compilers and model updates
- control logic
- HTTP transport handlers
- the cqueues ↔ fibers bridge
- single-service API logic

These tests should form the bulk of the suite.

### Dev-host integration tests

These tests run on a normal development machine and exercise multiple real services together in one Lua process.

They are used to verify:

- service boot and shutdown
- retained bus state
- request/reply flows
- failure propagation between scopes
- interaction between `main`, `config`, `net`, `ui` and HAL-facing boundaries

These tests usually use:

- the real bus
- the real fibers runtime
- real service modules
- a fake HAL service or fake HAL-backed service loader

The aim is to test service composition without requiring OpenWrt or physical hardware.

### OpenWrt VM tests

These are intended for a real OpenWrt userspace running in a VM.

They should focus on the OpenWrt boundary rather than re-testing pure logic. In particular:

- state store behaviour
- UCI apply logic
- process execution
- filesystem interactions
- link and counter inspection
- service reload and restart behaviour

These tests prove that the OpenWrt backend talks to the operating system correctly.

### Real hardware tests

These are intended for the smallest, highest-value set of checks.

They should cover things a VM cannot prove, such as:

- modem and Wi-Fi hardware behaviour
- UART-connected peers
- PoE switch integration
- reboot and persistence behaviour
- upgrade and rollback paths
- board-specific capability discovery

## Current structure

The suite is arranged by layer first, then by subject.

In broad terms:

- `unit/` contains isolated module tests
- `integration/devhost/` contains multi-service host-side integration tests
- `support/` contains shared helpers used by both kinds of tests

The support helpers include, for example:

- `run_fibers.lua` for running tests inside the fibers runtime
- `bus_probe.lua` for waiting on retained or live bus messages
- `fake_hal.lua` for scripted HAL behaviour
- `stack_diag.lua` for collecting bus traces and fake HAL call history when an integration test fails

## Test conventions

A few conventions are used throughout the suite.

### Prefer narrow assertions

Each test should prove one thing clearly. If a test covers too much, failures become hard to interpret.

### Use real services where practical

In dev-host integration tests, prefer real service modules and fake only the outer system boundary, especially HAL.

### Treat readiness explicitly

Services start asynchronously. Tests should wait for a clear readiness signal before publishing control messages or expecting downstream effects.

Typical readiness signals are:

- retained `obs/state/...` topics
- retained `svc/.../announce` topics
- explicit status publications
- captured hooks in test-only service wiring

### Diagnose failures with traces

Where a stack test can fail for several reasons, use `stack_diag.lua` so that the failure includes:

- observed bus traffic
- retained state transitions
- fake HAL call history

This keeps integration-test failures evidence-led rather than speculative.

### Keep timing short but realistic

Timeouts should be short enough for fast feedback, but not so tight that scheduler jitter causes false failures.

## Fake HAL usage

There are two related but different testing patterns around HAL.

### Fake HAL service

Used when testing domain services such as `config`, `net` or `ui` against a scripted HAL-facing contract.

### Host-side HAL-backed service wiring

Used when testing `devicecode.main` and a real service stack, while still avoiding real OS and hardware effects.

The intent is to fake the system boundary, not to fake the services under test.

## Running the tests

The suite is normally run from the `tests` directory using the local runner.

For example:

```sh
luajit run.lua
````

If the runner is extended later, it may support filtering by layer or path.

## What the suite is trying to protect

At a high level, the tests are intended to protect the following design properties:

* scopes give reliable cancellation and shutdown
* services are decoupled and communicate over the bus
* configuration is treated as data and validated in layers
* HAL contains OS and hardware dependency
* bounded communication does not create unbounded memory growth
* the control plane remains testable off-device
* OpenWrt-specific behaviour is checked in the right environment
* hardware-specific behaviour is checked only where hardware is needed

## Adding new tests

When adding a test, start by asking which layer it belongs to.

* If it checks pure logic, it is a unit test.
* If it checks service interaction without real OpenWrt, it is a dev-host integration test.
* If it checks real OpenWrt behaviour, it is a VM test.
* If it checks actual board or peripheral behaviour, it is a hardware test.

Keep helpers in `support/` when they are broadly reusable. Keep fixtures and scripts close to the layer that uses them.

## Present coverage

At present the suite includes tests around:

* config codec and state handling
* net model and control helpers
* service boot wiring in `main`
* config and net service behaviour
* UI handler and API flows
* cqueues bridge behaviour
* dev-host stack integration for `main`, `config`, `net`, `ui` and fake HAL
* persistence failure and recovery paths

This should continue to grow by adding depth at the service boundary, not by making individual tests excessively broad.
