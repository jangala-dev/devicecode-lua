## Fabric

### Role

Fabric owns link-oriented communication between local services and imported or peer surfaces.

It is responsible for:

```text
configured links
session establishment
frame reading and writing
RPC bridging
retained-state bridging
transfer management
link state publication
```

### Public surfaces

Fabric publishes canonical retained link state under:

```text
state/fabric/link/<link>
state/fabric/link/<link>/component/<component>
```

Fabric exposes the public transfer manager under:

```text
cap/transfer-manager/main/meta
cap/transfer-manager/main/status
cap/transfer-manager/main/rpc/send-blob
```

Imported remote truth should be represented as provenance-bearing raw truth, for example:

```text
raw/member/<source>/...
raw/member/<source>/cap/<class>/<id>/...
```

### Lifetime shape

```text
fabric service scope
  coordinator
  transfer-manager public capability binding
  generation scope
    link scopes
      transport-open work
      reader
      writer
      session control
      RPC bridge
      transfer manager
      state publisher
```

### Rules

Fabric can be the reference service for complex scoped composition.

Link workers report through service event ports. Link completions carry identity and generation. Stale completions are ignored.

Transfer admission must preserve ownership transfer:

```text
failed admission -> sender still owns source
successful admission -> receiver owns source cleanup
```

Fabric must not expose transport-specific provider details through curated `cap/...` surfaces.
