# Legacy MCU Fabric adapter

`bigbox-v1-cm` uses `legacy_mcu_metrics_v1` to translate the scalar JSON emitted
by `dc-go-10-4` into the raw retained facts imported from `dc-go-11-0` by
`fabric_jsonl_v1`. Both feed the device service through
`raw/member/<member>/state/...`; the device service owns UI projections and
metric publication. The legacy adapter no longer publishes `obs/v1/mcu/metric/*`.

| Legacy input key | Raw fact suffix | Payload field |
| --- | --- | --- |
| `power/battery/internal/vbat` | `power/battery` | `pack_mV` |
| `power/battery/internal/ibat` | `power/battery` | `ibat_mA` |
| `power/battery/internal/bsr` | `power/battery` | `bsr_uohm_per_cell` |
| `power/temperature/internal` | `power/battery` | `temp_mC` (deci-C multiplied by 100) |
| `power/charger/internal/vin` | `power/charger` | `vin_mV` |
| `power/charger/internal/vsys` | `power/charger` | `vsys_mV` |
| `power/charger/internal/iin` | `power/charger` | `iin_mA` |
| `power/charger/internal/state/*` | `power/charger` | `state_bits` |
| `power/charger/internal/status/*` | `power/charger` | `status_bits` |
| `power/charger/internal/system/*` | `power/charger` | `system_bits` |
| `env/temperature/core` | `environment/temperature` | `deci_c` (already deci-C) |
| `env/humidity/core` | `environment/humidity` | `rh_x100` (already hundredths) |
| `sys/mem/alloc` | `runtime/memory` | `alloc_bytes` |

Named 0/1 charger flags are packed using the LTC4015 masks used by the new MCU.
Each JSON line is validated and accumulated before publishing at most one
snapshot per affected fact. Snapshots do not share mutable tables. Unknown keys
are ignored. `change_only` suppresses identical fact snapshots, not individual
scalar fields. Retained facts are removed on EOF, failure, or cancellation.

Battery facts include `presence`, `measurements_valid`, and an optional `reason`.
Missing and short flags determine absent/fault states. Until both flags have
been observed clear, presence is unknown. A present battery also needs pack
voltage and current samples before measurements are valid. Invalid battery
facts omit analog readings. The latest samples remain cached internally, as in
the new MCU, and can be exposed when the charger reports a present battery.

No per-cell voltage, MCU sequence number, uptime, software identity, or other
unavailable fields are invented. The transport remains one-way: legacy firmware
cannot provide Fabric sessions, RPC, transfers, or structured charger events.

## Configuration migration

Keep `kind: "legacy_mcu_metrics_v1"`. Remove the obsolete `namespace_prefix` and
`publish_service` arguments; use `member` (default `mcu`) to select the raw topic
prefix. The bundled `bigbox-v1-cm.json` includes the device fact subscriptions.
Consumers of direct `obs/v1/mcu/metric/*` topics must use device-service metrics
or the raw facts instead. Metric names and measurement namespaces are generated
by the same device implementation as for the new MCU.

`unsigned_underflow_compat` remains enabled by default, but only unwraps signed
current/temperature fields in the uint32 wrap range. It never changes large
memory readings or unsigned battery resistance. Units follow the supplied
`dc-go-10-4` wire output; already-converted Celsius/percent input is not this
protocol's input contract.
