## Timeout and cancellation discipline in `devicecode`

This note sets out the preferred style for timeouts and cancellation in `devicecode` services built on `fibers`.

It does **not** propose changes to the `fibers` core library. The goal is to make service code more uniform while preserving the explicit, compositional style that makes `fibers` useful.

### Purpose

We want code to make progress conditions explicit.

In particular:

* blocking conditions should be expressed as composable ops
* timeout should usually appear as an ordinary arm in a visible `op.choice(...)`
* cancellation should remain ambient and structural via scopes
* larger actions with side effects should be quarantined in their own scope and then raced as a whole

### Core rules

#### 1. Keep `choice(...)` visible

Do not hide important progress logic behind deep helper stacks.

The intended style is that readers can see, in one place, the conditions under which work will proceed or stop.

A timeout should therefore usually be written as an explicit op arm, not buried inside a wrapper that obscures the composition.

#### 2. Convert relative timeout to absolute deadline once

At a service edge it is fine to accept `timeout_s`.

Once the operation begins, convert it immediately to:

```lua
local deadline = fibers.now() + timeout_s
```

From that point onward, pass `deadline` internally and prefer deadline-shaped timeout arms, usually:

```lua
sleep.sleep_until_op(deadline)
```

Avoid inventing fresh relative sleeps deeper in the call chain.

Within an operation, `deadline` is the preferred time-budget currency. Helpers should usually accept `deadline` rather than inventing fresh relative timeouts of their own.

#### 3. Timeout is an explicit outcome, not cancellation

Timeout and cancellation are different things.

* **timeout** means the timeout arm won the race
* **cancellation** means the surrounding scope was cancelled

Do not translate ambient cancellation into timeout.

#### 4. Quarantine complex work in a child scope

If an action:

* has side effects
* performs retries
* allocates temporary resources
* or contains several internal waits

then consider running it in a child scope using `scope:run_op(...)` or `fibers.run_scope_op(...)`, and race that whole scoped action against a timeout arm.

Use this when the work benefits from scope-bounded cleanup, descendant cancellation, or side-effect quarantine.

#### 5. Distinguish timeout, failure and cancellation clearly

Service code should preserve the distinction between:

* success
* failure
* timeout
* cancellation

These have different operational meanings and should not be merged casually.

### Canonical patterns

#### Pattern A: timeout as an explicit arm

```lua
local deadline = fibers.now() + timeout_s

local timeout_op = sleep.sleep_until_op(deadline):wrap(function ()
  return nil, 'timeout'
end)

return fibers.choice(
  do_something_op(...),
  timeout_op
)
```

This is the default form for a bounded wait.

#### Pattern B: quarantined work raced against timeout

```lua
local deadline = fibers.now() + timeout_s

local timeout_op = sleep.sleep_until_op(deadline):wrap(function ()
  return nil, 'timeout'
end)

return fibers.choice(
  fibers.run_scope_op(function (s)
    return do_complex_thing(s, ...)
  end),
  timeout_op
)
```

Use this when the operation is more than a single simple wait and benefits from scope-bounded cleanup, descendant cancellation, or side-effect quarantine.

#### Pattern C: observe-until loop with deadline

```lua
local deadline = fibers.now() + timeout_s
local seen = current_version()

while true do
  local done, result = evaluate()
  if done then
    return result
  end

  local timeout_op = sleep.sleep_until_op(deadline):wrap(function ()
    return nil, 'timeout'
  end)

  local changed, err = fibers.choice(
    changed_op(seen):wrap(function ()
      return true
    end),
    timeout_op
  )

  if not changed then
    return nil, err
  end

  seen = current_version()
end
```

Use this when completion is determined by observed state rather than a single direct operation.

### Service-level guidance

#### `update`

Use absolute deadlines for:

* stage acceptance
* commit acceptance
* post-reboot reconcile

Keep the timeout arm explicit. For commit and reconcile, prefer racing a quarantined scoped action rather than many small internal relative timeouts.

#### `fabric`

For transfers, RPC, and connection work:

* keep the relevant ops visible in `choice(...)`
* include timeout as one named arm
* prefer deadlines over accumulated relative sleeps

For operations with retries or sub-phases, make the overall deadline explicit.

#### `device`

For component observation and staleness:

* track an absolute stale deadline
* compose normal observation ops with a stale timeout op
* treat staleness as a normal observed outcome, not cancellation

#### `ui`

For model waits and uploads:

* keep the change/progress condition explicit
* add timeout as a visible arm
* quarantine multi-step staging work in a child scope where appropriate

### Naming conventions

Use these names consistently:

* `deadline` for the absolute timeout boundary
* `timeout_op` for the timeout arm
* `remaining` for `deadline - fibers.now()`

Avoid mixing several synonyms such as `expiry`, `until`, `timeout_at`, unless a module has a very good reason.

### What not to do

Do not:

* add new timeout primitives to `fibers` for this purpose
* hide core progress logic behind large wrapper functions
* use many unrelated local timeout idioms across services
* treat cancellation as if it were a timeout
* keep adding fresh relative sleeps as work progresses

### Summary

The preferred style is:

* explicit `choice(...)`
* explicit timeout arm
* absolute deadlines as the internal time budget
* ambient cancellation via scopes
* quarantined complex work via `run_scope_op(...)` where appropriate

This preserves the compositional power of `fibers` while making timeout and cancellation behaviour more uniform across services.
