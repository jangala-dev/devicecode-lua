## Device

### Role

Device is the authoritative appliance composition service.

It observes raw host, member, Fabric and HAL-facing truth, then publishes curated appliance component truth.

Device is not a raw RPC router. It owns public component semantics.

### Public surfaces

Device publishes canonical appliance truth under:

```text
state/device/identity
state/device/components
state/device/component/<component>
state/device/component/<component>/software
state/device/component/<component>/update
```

Device publishes curated component interfaces under:

```text
cap/component/<component>/meta
cap/component/<component>/status
cap/component/<component>/rpc/<method>
```

Provider-native backing facts and interfaces remain under `raw/...`. Device capability metadata should include provenance references to backing raw topics and interfaces.

### Lifetime shape

```text
device service scope
  coordinator
  service-owned model
  publisher
  generation scope
    component observers
    component action bindings
    fabric-stage action workers
```

### Rules

The service owns the public model.

A generation owns catalogue-dependent observers and action bindings.

Observers own raw watches.

Actions own caller-visible requests and blocking work.

Device should not mirror every raw capability. It should curate stable appliance-level component surfaces.

Fabric-stage actions use Fabric transfer targets such as:

```text
updater/main
```
