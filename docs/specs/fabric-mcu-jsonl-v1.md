# Fabric MCU link contract: `fabric-jsonl/1`

## 1\. Transport

The wire transport is newline-delimited JSON.

```
one JSON object per line
UTF-8 JSON
line terminator: \n
no length prefix
no binary payloads directly in JSON
```

Binary transfer chunks are carried as unpadded base64url strings.

## 2\. Session handshake

Every session starts with versioned hello frames.

```json
{
  "type": "hello",
  "proto": "fabric-jsonl/1",
  "sid": "cm5-session-id",
  "node": "cm5",
  "identity": null,
  "auth": null
}
```

```json
{
  "type": "hello_ack",
  "proto": "fabric-jsonl/1",
  "sid": "mcu-session-id",
  "node": "mcu",
  "identity": null,
  "auth": null
}
```

Required fields:

| Field | Meaning |
| :---- | :---- |
| `type` | `hello` or `hello_ack` |
| `proto` | must be `fabric-jsonl/1` |
| `sid` | non-empty session id |
| `node` | sender node name |
| `identity` | optional claimed stable fabric identity object, or `null` |
| `auth` | optional authentication negotiation/proof object, or `null` |

`identity` and `auth` are reserved for stable peer identity and authentication. For `fabric-jsonl/1`, the MCU may omit them, send them as null, and ignore them when received.

If present, `identity` is only a claim until authenticated. Unauthenticated identity must not be used for trust, authorisation, routing policy, update authority, or durable peer identity.

`node` remains the short wire speaker label. It is not a stable authenticated fabric identity. `sid` remains an ephemeral session id. It is not a peer identity. A local `link_id`, if used by the CM5 implementation, identifies the configured local link instance only.

Use `node` on the wire. Lua may call it `node_id` internally.

If `proto` is missing or unsupported, the peer must not treat the session as established.

Liveness frames:

```json
{ "type": "ping", "sid": "..." }
{ "type": "pong", "sid": "..." }
```

The MCU should treat a new peer session id as a fresh link session. The CM5 will also treat a new MCU session id as a new link session.

### Reserved identity and authentication objects

These objects are reserved in v1 so that later fabric links can distinguish local link instances, wire speaker labels, and authenticated fabric peers.

The MCU v1 implementation is not required to populate or verify these fields.

Example future identity object:

```json
{
  "id": "fabric-peer-id",
  "kind": "fabric-peer",
  "roles": ["bigbox"]
}
```

Example future auth object:

```json
{
 "scheme": "reserved",
 "nonce": "base64url-random",
 "proof": null
}
```

Rules for v1:

```
identity may be omitted or null
auth may be omitted or null
unknown identity fields must be ignored
unknown auth fields must be ignored
identity is not trusted unless authentication succeeds
authentication schemes are reserved and not required for MCU v1
```

## 3\. Frame classes

The frame `type` determines routing.

| Class | Frame types |
| :---- | :---- |
| session control | `hello`, `hello_ack`, `ping`, `pong` |
| RPC/state | `pub`, `unretain`, `call`, `reply` |
| transfer control | `xfer_begin`, `xfer_ready`, `xfer_need`, `xfer_commit`, `xfer_done`, `xfer_abort` |
| transfer bulk | `xfer_chunk` |

## 4\. Topics

Topics are JSON arrays of strings or numbers.

Examples:

```json
["state", "self", "software"]
["event", "self", "power", "charger", "alert"]
["cap", "self", "updater", "main", "rpc", "prepare-update"]
```

Remote MCU topics follow this model.

| MCU wire topic prefix | Meaning on CM5 side |
| :---- | :---- |
| `["state", "self", ...]` | retained MCU facts imported to `raw/member/mcu/state/...` |
| `["event", "self", ...]` | MCU events imported to `raw/member/mcu/cap/telemetry/main/event/...` |
| `["cap", "self", "updater", "main", "rpc", <method>]` | RPC call to MCU updater capability |

The MCU must not emit `raw/member/...` topics on the wire. Those are CM5-side provenance topics.

## 5\. Retained state required from the MCU

The MCU must publish retained state using `pub` frames with `retain: true`.

The minimum required retained facts for the update system are:

```
state/self/software
state/self/updater
```

The broader retained state set is:

```
state/self/software
state/self/updater
state/self/health
state/self/power/battery
state/self/power/charger
state/self/power/charger/config
state/self/environment/temperature
state/self/environment/humidity
state/self/runtime/memory
```

The MCU should publish the current retained state promptly after session establishment, and again whenever it changes.

### `state/self/software`

This is required. It describes the image currently booted and running.

Example:

```json
{
  "type": "pub",
  "topic": ["state", "self", "software"],
  "retain": true,
  "payload": {
    "version": "1.2.3",
    "build_id": "2026-05-04T120000Z",
    "image_id": "mcu-image-abc123",
    "boot_id": "boot-unique-id-456",
    "payload_sha256": "64-lowercase-hex"
  }
}
```

Required fields:

| Field | Requirement |
| :---- | :---- |
| `image_id` | stable identity of the currently running firmware image |
| `boot_id` | unique identity for this boot of the MCU |

Strongly recommended fields:

| Field | Meaning |
| :---- | :---- |
| `version` | human-readable firmware version |
| `build_id` | build identity |
| `payload_sha256` | SHA-256 of the firmware payload from the `.dcmcu` manifest |

`boot_id` requirements:

```
Generated once per MCU boot.
Stable for the whole boot.
Changes after every successful reboot.
Must not be derived only from image_id.
Must be published before the CM5 is expected to reconcile update success.
```

This is part of the update correctness contract. The CM5 update flow captures the pre-commit `boot_id` before committing an update. After commit and reboot, it expects to see the target `image_id` and a different `boot_id`. Without this, the CM5 cannot reliably distinguish “image staged or reported” from “new image actually booted”.

### `state/self/updater`

This is required. It describes the MCU updater’s current state.

Example:

```json
{
  "type": "pub",
  "topic": ["state", "self", "updater"],
  "retain": true,
  "payload": {
    "state": "ready",
    "last_error": null,
    "pending_version": null,
    "pending_image_id": null,
    "staged_image_id": null,
    "job_id": null
  }
}
```

Required fields:

| Field | Requirement |
| :---- | :---- |
| `state` | current updater state |
| `last_error` | last updater error, or `null` |

Recommended fields:

| Field | Meaning |
| :---- | :---- |
| `pending_version` | version of staged or pending image, if known |
| `pending_image_id` | image expected to be booted after commit |
| `staged_image_id` | image currently staged |
| `job_id` | current update job id, if any |

Allowed `state` values for v1:

```
ready
preparing
receiving
staged
committing
rebooting
running
failed
rollback_detected
```

`ready` and `running` both mean the updater is not currently in a failed state. `failed` and `rollback_detected` are terminal failure states for update reconciliation.

The MCU should publish updater state changes at these points:

```
after boot
after prepare accepted
after transfer begins
after transfer is staged
after commit accepted
before reboot, if possible
after reboot
after any update failure
after rollback detection
```

The “before reboot” publication is useful but not guaranteed to be observed. The authoritative result of an update is the post-reboot retained state.

### `state/self/health`

Recommended.

Example:

```json
{
  "type": "pub",
  "topic": ["state", "self", "health"],
  "retain": true,
  "payload": {
    "state": "ok"
  }
}
```

Acceptable simple payloads:

```json
"ok"
```

or:

```json
{ "state": "ok" }
```

Suggested states:

```
ok
degraded
failed
unknown
```

### Power, charger and environment facts

These are device model. They are not required for firmware update correctness, but they are part of the expected MCU telemetry surface.

#### `state/self/power/battery`

```json
{
  "pack_mV": 12800,
  "per_cell_mV": 3200,
  "ibat_mA": -120,
  "temp_mC": 24500,
  "bsr_uohm_per_cell": 12000,
  "seq": 42,
  "uptime_ms": 123456
}
```

#### `state/self/power/charger`

```json
{
  "vin_mV": 24000,
  "vsys_mV": 12800,
  "iin_mA": 500,
  "state_bits": 0,
  "status_bits": 0,
  "system_bits": 0,
  "seq": 43,
  "uptime_ms": 123500
}
```

The MCU may also include decoded sub-objects:

```json
{
  "state": {},
  "status": {},
  "system": {}
}
```

#### `state/self/power/charger/config`

```json
{
  "schema": "charger-config/1",
  "source": "mcu",
  "alert_mask_bits": 0,
  "thresholds": {
    "vin_lo_mV": 11000,
    "vin_hi_mV": 26000,
    "bsr_high_uohm_per_cell": 50000
  },
  "alert_mask": {
    "vin_lo": true,
    "vin_hi": true,
    "bsr_high": true,
    "bat_missing": true,
    "bat_short": true,
    "max_charge_time_fault": true,
    "absorb": true,
    "equalize": true,
    "cccv": true,
    "precharge": true,
    "iin_limited": true,
    "uvcl_active": true,
    "cc_phase": true,
    "cv_phase": true
  },
  "seq": 44,
  "uptime_ms": 123600
}
```

#### `state/self/environment/temperature`

```json
{
  "deci_c": 234,
  "seq": 45,
  "uptime_ms": 123700
}
```

#### `state/self/environment/humidity`

```json
{
  "rh_x100": 4512,
  "seq": 46,
  "uptime_ms": 123800
}
```

#### `state/self/runtime/memory`

```json
{
  "alloc_bytes": 12345,
  "seq": 47,
  "uptime_ms": 123900
}
```

## 6\. MCU events

The event is:

```
event/self/power/charger/alert
```

Example:

```json
{
  "type": "pub",
  "topic": ["event", "self", "power", "charger", "alert"],
  "retain": false,
  "payload": {
    "kind": "vin_lo",
    "severity": "warning",
    "source": "charger",
    "state_bits": 0,
    "status_bits": 0,
    "system_bits": 0,
    "seq": 48,
    "uptime_ms": 124000
  }
}
```

Known charger alert kinds:

```
vin_lo
vin_hi
bsr_high
bat_missing
bat_short
max_charge_time_fault
absorb
equalize
cccv
precharge
iin_limited
uvcl_active
cc_phase
cv_phase
```

Unknown alert kinds should still be forwarded; the CM5 will mark them as not known.

## 7\. Pub/sub frames

Retained state:

```json
{
  "type": "pub",
  "topic": ["state", "self", "software"],
  "retain": true,
  "payload": {
    "image_id": "mcu-image-abc123",
    "boot_id": "boot-unique-id-456"
  }
}
```

Non-retained event:

```json
{
  "type": "pub",
  "topic": ["event", "self", "power", "charger", "alert"],
  "retain": false,
  "payload": {
    "kind": "vin_lo",
    "severity": "warning"
  }
}
```

Remove retained state:

```json
{
  "type": "unretain",
  "topic": ["state", "self", "updater"]
}
```

The MCU should avoid unretaining required facts during normal operation. If a fact is temporarily unknown, prefer retaining a payload with an explicit state such as `unknown`, `unavailable`, or `last_error`.

## 8\. RPC frames

Call:

```json
{
  "type": "call",
  "id": "call-123",
  "topic": ["cap", "self", "updater", "main", "rpc", "prepare-update"],
  "payload": {
    "job_id": "job-1",
    "target": "mcu",
    "expected_image_id": "image-id",
    "metadata": {}
  }
}
```

Successful reply:

```json
{
  "type": "reply",
  "id": "call-123",
  "ok": true,
  "payload": {
    "ready": true
  }
}
```

Failed reply:

```json
{
  "type": "reply",
  "id": "call-123",
  "ok": false,
  "err": "not_ready"
}
```

Rules:

```
id is chosen by caller.
reply.id must match call.id.
ok is authoritative.
err is a short string when ok is false.
payload is arbitrary JSON when ok is true.
Unknown payload fields should be ignored.
```

Required MCU updater RPC methods for v1:

```
cap/self/updater/main/rpc/prepare-update
cap/self/updater/main/rpc/commit-update
```

The previous idea of `receive` is retained conceptually, but not as a required MCU RPC. In v1, binary staging is the transfer target:

```
updater/main
```

## 9\. Updater RPC behaviour

### `cap/self/updater/main/rpc/prepare-update`

Host payload:

```json
{
  "job_id": "job-1",
  "target": "mcu",
  "expected_image_id": "image-id",
  "metadata": {}
}
```

MCU behaviour:

```
Check that updater is available.
Check that no incompatible update is already active.
Clear or supersede stale staging state for the same updater target, if safe.
Record job_id and expected_image_id, if supplied.
Publish state/self/updater with state preparing or ready.
Reply ok only when the MCU can accept the transfer.
```

Suggested success reply:

```json
{
  "ready": true,
  "target": "updater/main",
  "max_chunk_size": 2048
}
```

Suggested failure strings:

```
busy
not_ready
unsupported_target
storage_unavailable
invalid_request
```

### `cap/self/updater/main/rpc/commit-update`

Host payload:

```json
{
  "job_id": "job-1",
  "expected_image_id": "image-id",
  "metadata": {}
}
```

The commit RPC is a cut-over command. Once the CM5 sends it, both the MCU and CM5 may reboot or lose the link immediately. The MCU should reply before reboot if practical, but the CM5 must not require the reply for update success.

MCU behaviour:

```
Check that a staged image exists.
Check that the staged image matches expected_image_id, if supplied.
Validate the staged .dcmcu container.
Make the selected boot image durable according to MCU safety policy.
Record enough updater state to report the result after reboot.
Publish state/self/updater with state committing or rebooting, if practical.
Reply before reboot if practical.
Trigger or allow the reboot/power-cycle.
After reboot, publish state/self/software with image_id and a new boot_id.
After reboot, publish state/self/updater with the final updater state.
```

Suggested success reply, if the reply can be delivered before reboot:

```json
{
  "accepted": true,
  "reboot_required": true
}
```

Suggested failure strings:

```
no_staged_image
image_id_mismatch
validation_failed
commit_failed
not_ready
```

A commit reply is advisory. The authoritative result is retained state observed after both devices have restarted and the fabric link has been re-established.

## 10\. Transfer protocol

Transfer is used for firmware staging.

The sender sends raw bytes. The wire encodes chunks as unpadded base64url. Size, offsets and digests are over the raw bytes, not the encoded JSON strings.

Digest decisions:

```
transfer digest_alg = "xxhash32"
transfer digest     = lower-case 8-character hex xxHash32, seed 0, over the complete raw artefact

chunk_digest        = lower-case 8-character hex xxHash32, seed 0, over the decoded raw chunk bytes
```

The transfer digest is the authoritative transport integrity check for the complete artefact.

The per-chunk digest is an early corruption-detection and retry aid. It allows the receiver to reject a bad chunk before writing it or before advancing the expected offset. It is not sufficient to prove that the complete transfer is valid.

Neither digest replaces `.dcmcu` container validation, payload SHA-256 validation, or signature verification.

### Begin

```json
{
  "type": "xfer_begin",
  "xfer_id": "xfer-123",
  "target": "updater/main",
  "size": 123456,
  "digest_alg": "xxhash32",
  "digest": "1a2b3c4d",
  "meta": {
    "kind": "firmware",
    "component": "mcu",
    "job_id": "job-1",
    "image_id": "expected-image-id",
    "format": "dcmcu-v1"
  }
}
```

The receiver checks:

```
target is supported
size is acceptable
digest_alg is supported
digest is syntactically valid for digest_alg
there is no conflicting active transfer
staging storage can be opened
```

For `fabric-jsonl/1`, the only required digest algorithm is:

```
xxhash32, seed 0, encoded as 8 lower-case hexadecimal characters
```

Then the receiver replies:

```json
{
  "type": "xfer_ready",
  "xfer_id": "xfer-123"
}
```

and asks for the first chunk:

```json
{
  "type": "xfer_need",
  "xfer_id": "xfer-123",
  "next": 0
}
```

The receiver drives chunk offsets explicitly from offset zero.

### Chunk

```json
{
  "type": "xfer_chunk",
  "xfer_id": "xfer-123",
  "offset": 0,
  "data": "base64url-without-padding",
  "chunk_digest": "9abcdef0"
}
```

Required fields:

| Field | Meaning |
| :---- | :---- |
| `type` | must be `xfer_chunk` |
| `xfer_id` | transfer id |
| `offset` | raw byte offset of this chunk in the complete artefact |
| `data` | unpadded base64url encoding of the raw chunk bytes |
| `chunk_digest` | xxHash32 seed 0 over the decoded raw chunk bytes, as 8 lower-case hex characters |

Receiver behaviour:

```
Check xfer_id matches the active transfer.
Check offset is the next expected offset.
Decode data from unpadded base64url.
Check chunk_digest over the decoded raw bytes.
Reject the chunk if chunk_digest does not match.
Write raw bytes at offset only after the chunk digest has passed.
Advance the expected offset by the decoded byte count.
Send xfer_need with the next offset.
```

Example continuation request:

```json
{
  "type": "xfer_need",
  "xfer_id": "xfer-123",
  "next": 2048
}
```

Initial MCU chunk size target:

```
2048 bytes
```

Lua may configure this, but the first MCU implementation should be safe with 2048-byte raw chunks.

If the receiver detects a bad chunk before advancing the offset, it may either abort the transfer or ask again for the same offset. The simple V1 behaviour may be to abort.

Recommended simple failure:

```json
{
  "type": "xfer_abort",
  "xfer_id": "xfer-123",
  "err": "chunk_digest_mismatch"
}
```

### Commit

After all bytes are sent:

```json
{
  "type": "xfer_commit",
  "xfer_id": "xfer-123",
  "size": 123456,
  "digest_alg": "xxhash32",
  "digest": "1a2b3c4d"
}
```

Receiver verifies:

```
received byte count == size
computed xxhash32 over the complete raw artefact == digest
staged object is valid for target
```

Then:

```json
{
  "type": "xfer_done",
  "xfer_id": "xfer-123"
}
```

`xfer_done` means the complete object digest has been verified and the transferred object has been accepted by the transfer target. For firmware update, it means the `.dcmcu` container is staged sufficiently for the subsequent updater `commit` RPC. It does not mean the new firmware is running.

Failure at any point:

```json
{
  "type": "xfer_abort",
  "xfer_id": "xfer-123",
  "err": "digest_mismatch"
}
```

Suggested transfer failure strings:

```
busy
unsupported_target
unsupported_digest_alg
size_too_large
storage_unavailable
unexpected_offset
invalid_chunk_encoding
missing_chunk_digest
invalid_chunk_digest
chunk_digest_mismatch
short_transfer
digest_mismatch
validation_failed
timeout
aborted
```

---

## 11\. Firmware image artefact

For the bundled MCU update path, the transferred artefact is the complete `.dcmcu` image container, not only an extracted firmware payload.

The MCU should validate at least:

```
container magic
container format version
manifest JSON
manifest schema
component == "mcu"
target compatibility
payload length
payload SHA-256
signature, when enabled for the product/release path
```

The `.dcmcu` v1 manifest concepts are \- described canonically:

```json
{
  "schema": 1,
  "component": "mcu",
  "target": {
    "product_family": "bigbox",
    "hardware_profile": "bb-v1-cm5-2",
    "mcu_board_family": "rp2354a"
  },
  "build": {
    "version": "1.2.3",
    "build_id": "build-id",
    "image_id": "image-id"
  },
  "payload": {
    "format": "raw-bin",
    "length": 123456,
    "sha256": "64-lowercase-hex"
  },
  "signing": {
    "key_id": "key-id",
    "sig_alg": "ed25519"
  }
}
```

The CM5 may preflight the image, but the MCU remains the authority for whether an image is safe to stage and commit.

## 12\. Firmware update flow

The canonical MCU firmware update flow is:

```
prepare RPC
transfer to updater/main
durably record CM5 job state before commit
commit RPC
both MCU and CM5 may reboot or lose the link
post-boot retained-state reconciliation
```

### Step 1: current state before update

Before staging, the CM5 observes:

```
state/self/software.image_id
state/self/software.boot_id
state/self/updater.state
```

The CM5 stores the pre-commit `boot_id` in the durable update job.

### Step 2: prepare

Host calls:

```
cap/self/updater/main/rpc/prepare-update
```

Payload:

```json
{
  "job_id": "job-1",
  "target": "mcu",
  "expected_image_id": "image-id",
  "metadata": {}
}
```

MCU replies success when it can accept a staged update.

### Step 3: stage

Host sends the complete `.dcmcu` container using transfer:

```
target = "updater/main"
digest_alg = "xxhash32"
digest = xxhash32 over the complete transmitted container
chunk_digest = xxhash32 over each decoded raw chunk
```

The MCU must verify each `xfer_chunk.chunk_digest` before accepting the chunk.

The MCU must still verify the complete transfer digest at `xfer_commit`.

The MCU replies `xfer_done` only after:

```
all chunks have been accepted
received byte count matches xfer_commit.size
complete raw artefact xxhash32 matches xfer_commit.digest
the container has been durably staged enough for the subsequent commit step
```

Per-chunk digests are only an early corruption-detection mechanism. They do not prove that the complete artefact is correct.

### Step 4: durable pre-commit record on CM5

Before sending `cap/self/updater/main/rpc/commit-update`, the CM5 must durably record enough information to reconcile after a forced reboot.

Minimum durable fields:

```
job_id
target = mcu
expected_image_id
pre_commit_boot_id
pre_commit_image_id, if known
transfer digest_alg
transfer digest
transfer size
commit_state = about_to_commit or commit_sent
deadline / retry / reconciliation metadata
```

Required ordering:

```
durable job state written
then commit RPC sent
then assume lights out
```

This ordering is required because the MCU reboot also causes the CM5 to reboot.

### Step 5: commit

Host calls:

```
cap/self/updater/main/rpc/commit-update
```

Payload:

```json
{
  "job_id": "job-1",
  "expected_image_id": "image-id",
  "metadata": {}
}
```

The commit call is a cut-over command. Once sent, the CM5 must assume that both sides may reboot immediately.

The MCU should reply success if practical:

```json
{
  "accepted": true,
  "reboot_required": true
}
```

However, the CM5 must not treat absence of this reply as failure. The update result is determined after reboot.

### Step 6: post-boot reconciliation

After CM5 restart, the CM5 resumes the durable update job, reconnects fabric, and waits for retained MCU state.

The job succeeds when retained state shows:

```
state/self/software.image_id == expected_image_id
state/self/software.boot_id != pre_commit_boot_id
state/self/updater.state is not failed or rollback_detected
```

The job fails when retained state shows:

```
state/self/updater.state == failed
```

or:

```
state/self/updater.state == rollback_detected
```

or when the post-reboot state proves the old or wrong image is running after the reconciliation window.

Examples:

```
software.image_id != expected_image_id
software.boot_id != pre_commit_boot_id
```

means the MCU rebooted, but not into the expected image.

```
software.image_id == pre_commit_image_id
software.boot_id == pre_commit_boot_id
```

means the CM5 has not yet seen proof of a new MCU boot. The CM5 should keep waiting until the reconciliation deadline before declaring failure.

If the MCU boots the old image after an attempted update, it should publish one of:

```json
{
  "state": "rollback_detected",
  "last_error": "booted_previous_image"
}
```

or:

```json
{
  "state": "failed",
  "last_error": "commit_failed"
}
```

on:

```
state/self/updater
```

## 13\. Required implementation decisions frozen for v1

```
Wire protocol name: fabric-jsonl/1
Handshake field: proto
Hello may reserve identity and auth objects
node is a wire speaker label, not a stable authenticated identity
Topic format: JSON array
RPC reply model: call/reply by id, no reply topics
MCU state prefix: state/self
MCU event prefix: event/self
MCU updater RPC prefix: cap/self/updater/main/rpc
Required updater RPCs: prepare, commit
Transfer target for firmware: updater/main
Transfer digest field names: digest_alg, digest
Required transfer digest algorithm: xxhash32
xxhash32 format: 8 lower-case hex characters, seed 0
Chunk encoding: unpadded base64url
Per-chunk digest field: chunk_digest
Per-chunk digest algorithm: xxhash32, seed 0, over decoded raw chunk bytes
Per-chunk digest is required for xfer_chunk in v1
Final transfer digest remains required and authoritative
Initial chunk size: 2048 bytes
Firmware artefact: complete .dcmcu container
boot_id is required update-correctness state
Commit is a cut-over command
Commit reply is advisory
Update success requires post-boot image_id and boot_id reconciliation
```

## 14\. Compatibility deliberately not carried forward into the MCU contract

The MCU should not implement these ambiguities as part of the new v1 contract:

```
unversioned hello
checksum field
implicit first chunk after xfer_ready
xfer_chunk without chunk_digest
receiver-as-local-bus-topic in transfer metadata
receive RPC as the required staging path
raw/member/... topic names on the wire
update success based only on commit RPC success
update success without boot_id reconciliation
per-chunk digest as a substitute for final transfer digest
transfer digest as a substitute for .dcmcu payload SHA-256 or signature validation
```

