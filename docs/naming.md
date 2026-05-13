# Devicecode control-plane naming standard

## Status

Draft for team review.

## 0. Why this scheme exists

Devicecode has now grown beyond a simple in-process service runtime.

It has become a local control plane for:

* appliance composition
* imported internal members
* raw provider-native capabilities
* stable public manager interfaces
* retained workflow records
* canonical retained domain truth
* operator-facing local UI
* compatibility publication during migration

Earlier naming was developed while we were still conceiving the system. It's revealed not be be adequate once the system must clearly distinguish:

* raw provenance-bearing truth from curated public truth
* appliance composition from domain policy
* stable public interfaces from provider-native interfaces
* workflow managers from retained workflow instances
* intended behaviour from observed state
* canonical surfaces from temporary compatibility aliases

This scheme exists to make those distinctions **structural**, not merely conventional.

It is intended to ensure that public contracts remain stable even when:

* implementation placement changes
* transport changes
* a domain is split across multiple services
* a provider is replaced
* a raw source moves behind a compatibility seam
* or a service is renamed, decomposed or merged

The central change in this scheme is away from “whatever topic tree the current service happens to publish” and towards a control plane with explicit abstraction planes, explicit ownership and explicit provenance. One day this might become graph view projections over canonical objects, but not today!

## 1. Purpose

This specification defines the canonical control-plane naming model for Devicecode.

It gives stable answers to these questions:

* how are service lifecycle and intended configuration named?
* how is raw provenance-bearing truth separated from canonical public truth?
* how is appliance composition separated from domain policy state?
* how are stable public interfaces separated from raw provider-native interfaces?
* how are workflow manager interfaces separated from retained workflow instance records?
* how are durable desired state, retained workflow truth and immediate controls kept distinct?
* how is canonical public ownership declared?
* how are compatibility aliases handled during migration?
* how do public contracts survive changes in implementation placement, transport, decomposition and provider choice?

This specification governs control-plane naming, ownership and abstraction boundaries. It absolutely doesn't redefine fibers, bus semantics, scope semantics or service lifecycle rules.

## 2. Architectural position

This model preserves the non-negotiable Devicecode rules:

* services are implementation boundaries
* HAL is the only OS and hardware boundary
* services depend on interfaces, not on each other’s internals
* each service owns its own lifecycle and scoped connection

The following architectural rules are explicit.

> `device` is the authoritative appliance composition service.

`device` composes appliance-local truth from raw local, internal, imported and software-defined parts.

> Raw provenance-bearing surfaces (eg. hardware modem capability path) and curated public interfaces (eg. modem-1) MUST remain structurally segregated.

Metadata alone is not sufficient to preserve this distinction.

> Canonical retained domain truth MAY exist outside `device` where a domain service genuinely owns it.

Not all public retained truth is appliance composition truth.

> A service is an implementation boundary. A service is not, by itself, a public naming boundary.

A service MAY own one or more public naming families, but those families are justified by semantic ownership, not by the service name alone.

> `state/<domain>` names a semantic public domain, not the implementing service.

A domain family MUST NOT be introduced merely by copying the name of the service that currently publishes it.

> Durable intended behaviour SHOULD normally be expressed declaratively and reconciled by the owning service.

Imperative controls are the exception, not the default. For example, a modem is disabled by changing config, not by flipping a switch.

> Compatibility seams MAY exist at controlled branching points during migration.

A compatibility seam MUST preserve canonical ownership and MUST NOT become a second public architecture.

## 3. Normative language

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT** and **MAY** are to be interpreted as normative requirements.

## 3.1 Canonical, summary and compatibility surfaces

The following distinctions are normative.

* A **canonical surface** is the one authoritative public surface for an abstraction role.
* A **summary surface** is a deliberately reduced public projection of richer canonical truth.
* A **compatibility alias** is a temporary additional surface retained only to preserve compatibility during migration.

Compatibility aliases MUST:

* declare which canonical surface they mirror
* preserve the abstraction role of the canonical surface
* be implemented as one-way projections from canonical truth
* not become the dependency target of new work
* be sunsetted as soon as practicable

Summary surfaces MUST:

* clearly differ in abstraction role from the canonical surface they summarise
* not pretend to be the authoritative home of richer truth

## 4. Canonical top-level roots

The canonical top-level roots are:

* `svc`
* `cfg`
* `raw`
* `state`
* `cap`
* `obs`

No new top-level root SHOULD be introduced without strong justification.

`obs` is versioned below the root. The canonical initial observability plane is `obs/v1/...`.

`state` is the root for canonical retained state families.

The initial required canonical `state/...` families are:

* `state/device/...`
* `state/workflow/...`

Common additional domain families include:

* `state/update/...`
* `state/fabric/...`
* `state/gsm/...`
* `state/net/...`
* `state/wifi/...`
* `state/time/...`
* `state/site/...`

A narrow `state/ui/...` family MAY exist where the UI service owns genuine canonical retained UI-domain truth such as operator-facing session or model summaries. It MUST remain narrow and MUST NOT become the naming boundary for workflows owned elsewhere.

Any `state/<domain>/...` family MUST have one clearly identified owning service.

## 5. Canonical token form

Topics are represented in code as dense token arrays.

Slash form MAY be used in documentation.

Example:

* documentation: `cap/update-manager/main/rpc/create-job`
* code: `{ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }`

### 5.1 Token rules

* tokens MUST be lowercase
* multiword tokens MUST use kebab-case
* method names MUST use verbs in kebab-case
* curated public identifiers SHOULD be semantic and stable for the intended audience
* raw identifiers MAY be concrete, topology-bearing, provider-facing or transport-bearing where provenance requires it

## 6. Identifier scope and stability

Every identifier used in control-plane naming MUST have an intended scope and stability class.

At minimum, the following distinctions apply:

* **service ids** are runtime-local implementation identifiers
* **source ids** identify concrete provenance boundaries under `raw/...` and MAY be topology-bearing
* **component ids** identify appliance-level parts and SHOULD remain stable across routine reprovisioning, transport changes and provider replacement
* **domain ids** identify semantic domain-owned public instances, roles or summaries and SHOULD be stable for the intended domain audience
* **curated interface ids** identify stable local public interfaces under `cap/...`
* **raw ids** identify provider-native concrete interfaces and MAY be provider-facing or topology-bearing
* **workflow instance ids** identify retained operation records and MUST be unique within their workflow family

An identifier MUST NOT be reused casually across scopes with different meanings.

### 6.1 Service ids and domain ids

Service ids and domain ids are distinct.

* A **service id** identifies a runtime-local implementation boundary.
* A **domain id** identifies a stable semantic public audience or meaning.

A service id MUST NOT be assumed to define the correct `state/<domain>` family name.

A service MAY own canonical truth for a domain whose name differs from the service id.

A domain family SHOULD remain meaningful even if:

* the implementing service is renamed
* implementation is split across multiple services
* implementation is merged into another service
* the backing provider changes

### 6.2 Component ids and role ids

Component ids and role ids are distinct.

A component id identifies an appliance part, for example:

* `modem-1`
* `wifi-radio-2`
* `ethernet-port-1`

A role or semantic domain id identifies a domain-owned public meaning, for example:

* `primary`
* `secondary`
* `wan`
* `guest`
* `mesh`

A component id MUST NOT implicitly carry a domain role meaning.

A domain role mapping SHOULD be published explicitly by the domain service that owns that role.

## 7. Core address planes

## 7.1 `svc`: service lifecycle

Use `svc` for service lifecycle only.

Topics:

* `svc/<service>/status`
* `svc/<service>/meta`

This plane answers:

* is the service running?
* is it degraded?
* why did it fail?
* what build or version is it?

No business state, workflow state or configuration intent belongs under `svc`.

`svc/...` SHOULD remain intentionally boring.

## 7.2 `cfg`: intended service configuration and declarative policy input

Use `cfg` for the intended configuration and declarative policy input currently supplied to a service.

Topics:

* `cfg/<service>`

This plane answers:

* what configuration is this implementation boundary expected to reconcile against?
* what durable intended behaviour is this service being asked to achieve?

`cfg` is not persistence itself. Persistence MAY be provided by a capability, but `cfg/<service>` is the canonical intended-configuration plane.

`cfg/<service>` is not the general plane for “effective configuration currently in force”. If a service needs to distinguish between:

* intended configuration
* currently effective configuration
* last successfully applied or reconciled state

that distinction MUST be represented explicitly in canonical retained state rather than left ambiguous in `cfg/<service>`.

A configuration change MUST NOT be treated as a hidden imperative shortcut without the owning service’s reconciliation semantics.

## 7.3 `raw`: provenance-bearing truth and raw source-scoped interfaces

Use `raw` for concrete provenance-bearing truth and raw provider-native interfaces.

Topics:

* `raw/<kind>/<source>/meta`
* `raw/<kind>/<source>/status`
* `raw/<kind>/<source>/state/...`
* `raw/<kind>/<source>/cap/<class>/<id>/meta`
* `raw/<kind>/<source>/cap/<class>/<id>/status`
* `raw/<kind>/<source>/cap/<class>/<id>/state/<field>`
* `raw/<kind>/<source>/cap/<class>/<id>/event/<name>`
* `raw/<kind>/<source>/cap/<class>/<id>/rpc/<method>`

This plane answers:

* what concrete source exists?
* what did it actually publish or expose?
* what provider-native interfaces does it expose?
* what imported remote surfaces exist locally as provenance-bearing sources?

At minimum, each source MUST publish:

* `raw/<kind>/<source>/meta`
* `raw/<kind>/<source>/status`

### 7.3.1 Source kind semantics

`<kind>` identifies what sort of source this is.

Initial common values include:

* `host`
* `member`
* `peer`
* `software`

This vocabulary SHOULD remain small and stable.

Relation, placement and trust qualifiers such as `local`, `internal`, `federated`, `derived`, `managed` or `owner` SHOULD normally live in metadata, not in the path, unless there is strong justification for path-level distinction.

### 7.3.2 Raw source-wide state

`raw/<kind>/<source>/state/...` is for source-owned raw facts that are not naturally attached to a specific provider-native interface.

It MUST remain narrow.

It MUST NOT become a miscellaneous compatibility tree or a dumping ground for inconvenient facts.

Where a fact belongs to a raw provider-native interface, it SHOULD live under:

* `raw/<kind>/<source>/cap/<class>/<id>/state/<field>`

not under the source-wide state tree.

Legitimate source-wide raw state typically includes:

* source incarnation or generation
* session or link state
* source-wide health
* transport state
* source trust or assurance state
* source boot state
* source-wide diagnostics not naturally attached to a particular interface

### 7.3.3 Imported remote interfaces

Imported remote interfaces, even if curated at their point of origin, are locally treated as provenance-bearing source-scoped surfaces under `raw/...` unless and until deliberately re-curated into a local public alias.

### 7.3.4 Source ids

A source id under `raw/<kind>/<source>/...` MUST identify a concrete provenance boundary as observed locally.

A source id:

* MAY be topology-bearing
* MAY be transport-bearing where provenance requires it
* SHOULD remain stable for the local runtime while that source identity remains meaningful
* SHOULD NOT be re-used for a different concrete source merely because it occupies the same transport position later

Imported remote sources SHOULD normally be assigned a stable local source id by the importing service rather than exposing remote naming or transport details directly as the canonical local source id.

## 7.4 `state`: canonical retained state families

Use `state/...` for canonical retained state families.

This plane is for canonical public retained truth, not raw provider-native truth and not merely interface availability.

The initial required families are:

* `state/device/...`
* `state/workflow/...`

Additional domain families MAY be introduced where a service owns canonical public retained truth for its domain.

## 7.4.1 `state/device`: composed appliance truth

Use `state/device/...` for composed appliance-local truth.

This is the canonical place to ask:

* what appliance is this?
* what components does it have?
* what is their current state?
* what appliance-level summaries are true?

Only `device` publishes `state/device/...`.

Typical topics include:

* `state/device/identity`
* `state/device/components`
* `state/device/component/<component>`
* `state/device/component/<component>/software`
* `state/device/component/<component>/update`

`state/device/...` is for appliance-facing composed truth. It is not a dumping ground for raw provider state, workflow state or unrelated domain policy.

## 7.4.2 `state/workflow`: retained workflow truth

Use `state/workflow/...` for retained workflow instance records.

Examples:

* `state/workflow/update-job/<id>`
* `state/workflow/artifact-ingest/<id>`

Workflow state is public truth about concrete operations, not manager interfaces.

Not every action needs a workflow instance. This family SHOULD be used where the retained record is justified by the criteria in section 11.

## 7.4.3 `state/<domain>`: canonical retained domain truth

Use `state/<domain>/...` where a service owns canonical public retained truth for a semantic domain.

`state/<domain>` is **not** a synonym for `state/<service>`.

A domain family names the public domain audience and meaning of the truth, not the current implementation module or service boundary.

Therefore:

* `state/<domain>` MUST NOT be introduced merely because a service of the same name exists
* renaming, splitting or merging services SHOULD NOT by itself require renaming a `state/<domain>` family
* if the only justification for a family name is “this service publishes it”, that family name is not yet justified

Examples may include:

* `state/gsm/role/primary`
* `state/gsm/modem/modem-1`
* `state/net/interface/wan`
* `state/net/dns`
* `state/wifi/ap/main`
* `state/site/member/<id>`
* `state/update/summary`
* `state/update/component/mcu`
* `state/fabric/link/<id>`

A `state/<domain>/...` family MUST:

* have one clear owning service
* represent canonical public retained truth for that domain
* not merely restate raw provider-native truth
* not merely duplicate appliance composition truth
* not merely act as interface availability
* not merely be a workflow instance record

## 7.5 `cap`: stable public interfaces

Use `cap/...` for stable local public callable and inspectable interfaces intended for ordinary consumers.

Topics:

* `cap/<class>/<id>/meta`
* `cap/<class>/<id>/status`
* `cap/<class>/<id>/rpc/<method>`
* optionally `cap/<class>/<id>/event/<name>`
* narrowly and by exception, optionally `cap/<class>/<id>/state/<field>`

This plane answers:

* what stable local public interfaces exist?
* what methods can callers invoke?
* what broad interface-level condition applies?
* where justified, what small amount of interface-scoped retained state is part of the public contract?

Every address under `cap/...` MUST be intended as a stable public contract.

`cap/...` is the canonical local public interface plane. It includes both:

* stable feature interfaces
* stable manager interfaces

Examples include:

* `cap/modem/modem-1/rpc/connect`
* `cap/update-manager/main/rpc/create-job`
* `cap/artifact-ingest/main/rpc/commit`

Provider-native or topology-bearing concrete interfaces MUST NOT appear directly under `cap/...`.

`cap/...` is not a general retained state plane.

### 7.5.1 Ownership of `cap`

Any service MAY publish under `cap/...` where it owns a stable semantic public interface.

`device` MAY publish curated aliases for appliance-defining features.

Non-device services MAY publish stable public interfaces they own, including manager interfaces and domain feature interfaces.

`device` is authoritative for appliance composition. It is not the mandatory owner of every public interface.

### 7.5.2 Capability status

`cap/<class>/<id>/status` is for interface availability and broad operational condition only.

It MAY describe, for example:

* available or unavailable
* degraded
* broad reason or mode
* interface version or compatibility summary where useful

It MUST NOT be used as a substitute for canonical retained state.

In particular, `cap/.../status` MUST NOT quietly become a general state tree under another name.

`cap/.../status` SHOULD usually be summary-level and low-cardinality.

### 7.5.3 Capability events

`cap/<class>/<id>/event/<name>` MAY be used where a curated interface has meaningful interface-level events.

Events are optional.

They MUST NOT be used as authoritative retained state.

### 7.5.4 Narrow interface-scoped retained state

Some stable public interfaces MAY, by exception, publish a small amount of retained interface-scoped state under:

* `cap/<class>/<id>/state/<field>`

This is appropriate only where all of the following are true:

* the state is genuinely part of the interface contract rather than broad domain truth
* the state is naturally scoped to that one interface
* publishing it under `cap/...` materially improves inspectability or usability
* the interface-scoped state is not being used as the hidden canonical home of a larger retained state family

Examples that MAY be justified include:

* current ingest progress for a narrow public ingest interface
* current broad mode of a stable public manager interface
* a small interface-scoped summary that is meaningful to ordinary callers

If a richer retained state model exists, that richer canonical truth SHOULD usually live under:

* `state/device/...`
* `state/workflow/...`
* `state/<domain>/...`

and `cap/.../state/...` SHOULD remain summary-level.

If `cap/.../state/...` grows beyond a small interface adjunct, the design SHOULD be reconsidered.

### 7.5.5 Curated aliases and provenance

Where a curated public interface is backed by raw sources or raw provider-native interfaces, its `meta` SHOULD include references to those backing sources and interfaces.

Curated aliases MUST NOT erase provenance completely.

### 7.5.6 Common public interface patterns

The following patterns are recommended.

* Manager interfaces SHOULD use semantic manager classes such as:

  * `cap/update-manager/<id>/...`
  * `cap/artifact-ingest/<id>/...`
  * `cap/transfer-manager/<id>/...`

* Curated appliance-defining feature aliases published by `device` SHOULD normally use:

  * `cap/component/<component>/...`

* Provider-native interfaces MUST NOT be exposed directly under these curated classes. Where a provider-native interface is intentionally re-curated as a stable public alias, the alias `meta` SHOULD reference the backing raw source and raw interface.

* Stable utility interfaces MAY exist under `cap/...` only where they are intentionally public and are not merely convenient wrappers around raw provider-native utilities.

## 8. Declarative state, workflows and immediate controls

The normal Devicecode control-plane pattern is:

* durable intended behaviour enters through configuration
* services reconcile that intended behaviour into observed state
* structured operations are managed through stable public manager interfaces
* narrow immediate controls exist only where they are clearly justified

### 8.1 Durable desired state

Durable intended behaviour SHOULD normally be represented declaratively in service configuration or other canonical retained state owned by the appropriate service.

Examples include:

* modem preference and role policy
* APN policy
* network role assignment
* Wi-Fi configuration
* PoE policy
* update policy
* telemetry export policy

Public systems MUST NOT accumulate ad hoc imperative command trees for things that are really durable policy changes.

For update systems, durable desired behaviour such as bundled-image preference, approval policy or automatic reconcile policy SHOULD normally live in `cfg/update`.

`state/update/...` is for canonical retained update-domain truth such as current summary state, component-level update summaries or reconcile outcomes. It is not the canonical home of desired intent.

### 8.2 Workflow-managed operations

Workflow-managed operations are represented through stable public manager interfaces under `cap/...` and retained workflow instance records under `state/workflow/...`.

These are appropriate for operations that are at least one of:

* asynchronous
* multi-step
* reboot-spanning
* auditable
* operator-visible
* worth retaining after the initiating call completes

Examples include:

* uploaded artefact ingest
* update job creation
* update job approval
* update job commit
* support bundle generation
* onboarding and bootstrap flows

Workflow managers are not substitutes for durable policy. Durable policy belongs in configuration or canonical retained domain state, depending on ownership.

### 8.3 Immediate controls

Immediate controls are narrow, explicit actions that do not fit durable desired state and do not necessarily require a retained workflow instance.

Examples include:

* reboot the device
* power-cycle a member
* commit a prepared update job
* force a rescan
* acknowledge or clear a transient condition

An immediate control MUST NOT silently create durable policy unless that is its explicit and documented purpose.

### 8.4 Operational overrides

A service MAY define retained operational overrides where temporary intended behaviour needs to be represented declaratively without becoming long-lived user configuration.

Such overrides MUST be:

* explicitly modelled
* clearly owned by one service
* distinguishable from durable configuration
* distinguishable from immediate controls

## 9. Curated and raw segregation rules

The following rules are normative.

1. All stable public callable interfaces MUST live under `cap/...`.
2. All provider-native callable or inspectable interfaces MUST live under `raw/.../cap/...`.
3. No provider-native interface MAY also appear directly under `cap/...` without deliberate curation into a distinct alias.
4. Ordinary business services SHOULD depend on `cap/...`, not on `raw/...`.
5. `device` and other composing or orchestrating services MAY depend on `raw/...` where required.
6. Structural segregation MUST be preserved even where metadata could in principle distinguish the surfaces.

## 10. Device composition rules

The central composition rule is:

> Raw sources publish raw truth.
> Raw providers publish raw source-scoped interfaces.
> `device` composes appliance truth.
> Curated public interfaces are stable semantic contracts, not mirrors of raw topology.

### 10.1 What `device` publishes

`device` publishes:

* composed appliance truth under `state/device/...`
* explicit references to backing sources and interfaces where appropriate
* a curated subset of appliance-defining aliases under `cap/...`

### 10.2 What `device` MUST NOT do

`device` MUST NOT:

* mirror every raw source-scoped interface under a curated alias
* erase provenance completely
* absorb unrelated domain policy merely because it composes appliance state
* turn component ids into domain role ids

`device` is the authoritative appliance composition service. It is not the universal owner of all policy domains or all public interfaces.

## 11. Workflow rules

A workflow-managing public interface is a stable public manager interface under `cap/...`.

Examples include:

* `cap/update-manager/main/rpc/create-job`
* `cap/update-manager/main/rpc/commit-job`
* `cap/artifact-ingest/main/rpc/create`
* `cap/artifact-ingest/main/rpc/append`
* `cap/artifact-ingest/main/rpc/commit`
* `cap/artifact-ingest/main/rpc/abort`

A retained workflow record lives under:

* `state/workflow/...`

The manager is not the instance.

Not every action needs a workflow instance. Workflow records SHOULD be used for operations that are at least one of:

* asynchronous
* multi-step
* reboot-spanning
* auditable
* operator-visible
* worth retaining after the initiating call completes

Public workflows MUST NOT be exposed through ad hoc service-named command trees such as:

* `cmd/update/...`
* `cmd/ui/upload/...`

## 12. Canonical ownership rule

A fact MUST have one canonical public owner within its abstraction plane.

In particular:

* `raw/...` owns raw provenance-bearing truth
* `state/device/...` owns composed appliance truth
* `state/workflow/...` owns retained workflow instance truth
* `state/<domain>/...` owns canonical retained domain truth
* `cap/...` owns stable public interface contracts and broad interface status

If related truth appears in more than one plane, each occurrence MUST be justified by a distinct abstraction role.

For example:

* raw provider truth under `raw/...`
* composed appliance truth under `state/device/...`
* retained workflow instance truth under `state/workflow/...`
* retained domain truth under `state/<domain>/...`

may all legitimately describe the same real-world situation at different levels.

What is prohibited is casual mirroring of the same abstraction-role fact across multiple planes for convenience.

If equivalent truth appears in more than one place within the same abstraction role, one surface MUST be explicitly canonical and the others MUST be summaries, projections or compatibility aliases.

## 13. Minimal publication requirements

The following rules are normative.

1. Every service publishes:

   * `svc/<service>/status`
   * `svc/<service>/meta`
   * observability under `obs/v1/<service>/...`

2. Intended service configuration is published under:

   * `cfg/<service>`

3. Only `device` publishes:

   * `state/device/...`

4. Raw provenance-bearing truth is published under:

   * `raw/...`

5. Every source publishes:

   * `raw/<kind>/<source>/meta`
   * `raw/<kind>/<source>/status`

6. All stable public callable interfaces use:

   * `cap/<class>/<id>/rpc/<method>`

7. Every stable public curated interface publishes:

   * `cap/<class>/<id>/meta`
   * `cap/<class>/<id>/status`

8. All provider-native callable interfaces use:

   * `raw/<kind>/<source>/cap/<class>/<id>/rpc/<method>`

9. Retained workflow truth lives under:

   * `state/workflow/...`

10. Curated and raw capability surfaces MUST remain structurally segregated.

## 14. Decision guide

Use this quick test.

* Is this service lifecycle or build state?
  Use `svc/...`

* Is this intended configuration or declarative policy input for one service?
  Use `cfg/...`

* Is this raw provenance-bearing truth from a concrete source?
  Use `raw/...`

* Is this a raw provider-native callable or inspectable interface?
  Use `raw/.../cap/...`

* Is this composed appliance truth?
  Use `state/device/...`

* Is this canonical retained truth for a semantic public domain?
  Use `state/<domain>/...`

* Is this a retained record of a specific long-running or operator-visible operation?
  Use `state/workflow/...`

* Is this a stable local public interface?
  Use `cap/...`

* Is this an immediate control that is neither durable desired state nor a retained workflow?
  Use a narrow stable public interface under `cap/...`

* Is this logs, audit or observability rather than operational truth?
  Use `obs/v1/...`

### 14.1 `state/<domain>` versus service name

Before choosing `<domain>`, ask:

* would this family still have the same public meaning if the implementing service were renamed?
* would this family still have the same public meaning if implementation were split across multiple services?
* is the audience for this truth a domain audience rather than an implementation audience?

If the answer is no, this is probably not a `state/<domain>` family.

### 14.2 Public interface versus canonical retained state

When choosing between `cap/...` and `state/...`, apply this additional test.

Use `cap/...` when the thing you are naming is primarily:

* a callable method surface
* an inspectable interface contract
* a manager for creating or controlling operations
* a stable local alias for a semantic feature

Use `state/<domain>/...` or `state/device/...` when the thing you are naming is primarily:

* canonical retained truth for a domain or appliance audience
* a durable public summary of current reality
* a role mapping, selection result or composed view
* a state model that should remain meaningful even if the backing interface changes

If both exist, be explicit about which is canonical for which purpose:

* `cap/...` is canonical for invoking and inspecting the interface contract
* `state/...` is canonical for retained public truth

## 15. Compatibility publication

Compatibility aliases MAY be published temporarily during migration.

The following rules are normative.

1. A compatibility alias MUST name its canonical source in metadata or in the owning service documentation.
2. A compatibility alias MUST be implemented as a one-way projection from canonical truth.
3. New consumers MUST depend on canonical surfaces, not on compatibility aliases.
4. Compatibility aliases MUST NOT be used to bypass raw-versus-curated segregation.
5. Compatibility aliases SHOULD be removed once dependent consumers have migrated.

Compatibility publication is a migration tool, not a long-term architecture pattern.

## 16. Migration rule

Older public `cap/...` surfaces MAY remain as legacy-compatible public interface names where already shipped.

New work SHOULD adopt this model.

Compatibility aliases MAY exist temporarily, but canonical ownership MUST still be declared.

Raw-versus-curated segregation SHOULD improve over time and MUST NOT be broken for convenience.

## 17. Where we are now

Devicecode is now in the middle of a concrete migration to this model.

The current state after the `update-migration` PR stack establishes:

-   `raw/...` as the home of provenance-bearing imported member and host/provider surfaces
-   `state/device/...` as the canonical appliance composition plane
-   `state/workflow/...` as the retained workflow plane
-   `state/update/...` and `state/fabric/...` as domain-level retained summary planes
-   stable public managers such as:
    -   `cap/update-manager/...`
    -   `cap/artifact-ingest/...`
    -   `cap/transfer-manager/...`
-   curated component interfaces under:
    -   `cap/component/<component>/...`
-   compatibility seams at controlled branch points to project older surfaces from canonical truth during migration

This means the model is being landed through a stacked set of implementation PRs.

The main remaining work is not conceptual discovery but:

* tightening canonical ownership
* reducing compatibility publication
* and continuing migration of older surfaces and consumers

## 18. Next steps

The next steps are:

1. make canonical ownership explicit for all major published families
2. ensure new work depends only on canonical surfaces
3. narrow compatibility seams so that they remain migration tools rather than parallel architectures
4. retire legacy publication from raw/provider-facing areas before summary or observability aliases
5. strengthen tests so that they assert primarily on canonical surfaces
6. continue reviewing `cap/.../state/...` and `raw/.../state/...` for misuse
7. continue reviewing candidate `state/<domain>` families to ensure they are truly domain families, not service-local trees under another name

In practical terms, the near-term focus is:

* remove dependence on old `cmd/...` trees
* reduce legacy mirroring of provider-native capabilities
* make summary versus canonical versus compatibility surfaces explicit
* and keep `device` focused on appliance composition rather than raw mirroring or domain ownership creep

## 19. Migration appendix: worked examples

This appendix is non-normative, but strongly recommended.

### 19.1 Current migrated update manager

Manager interfaces:

* `cap/update-manager/main/rpc/create-job`
* `cap/update-manager/main/rpc/start-job`
* `cap/update-manager/main/rpc/commit-job`
* `cap/update-manager/main/rpc/cancel-job`
* `cap/update-manager/main/rpc/retry-job`
* `cap/update-manager/main/rpc/discard-job`

Retained workflow truth:

* `state/workflow/update-job/<id>`

Retained domain summaries:

* `state/update/summary`
* `state/update/component/mcu`

Durable desired bundled behaviour belongs in:

* `cfg/update`

not in retained workflow state.

### 19.2 Current migrated artifact ingest

A public ingest flow is modelled as:

* `cap/artifact-ingest/main/rpc/create`
* `cap/artifact-ingest/main/rpc/append`
* `cap/artifact-ingest/main/rpc/commit`
* `cap/artifact-ingest/main/rpc/abort`

Retained ingest truth lives under:

* `state/workflow/artifact-ingest/<id>`

The UI service may transport operator input to this manager, but the UI service is not the public naming boundary of the ingest workflow.

### 19.3 Current migrated fabric and device

Raw imported member truth:

* `raw/member/mcu/meta`
* `raw/member/mcu/status`
* `raw/member/mcu/state/...`
* `raw/member/mcu/cap/updater/main/...`

Fabric domain summaries:

* `state/fabric/link/<id>`
* `cap/transfer-manager/main/rpc/send-blob`

Device-composed appliance truth:

* `state/device/identity`
* `state/device/component/mcu`
* `state/device/component/mcu/software`
* `state/device/component/mcu/update`

Curated device-facing control:

* `cap/component/mcu/rpc/prepare-update`
* `cap/component/mcu/rpc/stage-update`
* `cap/component/mcu/rpc/commit-update`

### 19.4 HAL host/provider utilities

Raw host/provider utility surfaces may include:

* `raw/host/platform/cap/artifact-store/main/...`
* `raw/host/platform/cap/updater/cm5/...`

Curated public manager interfaces may include:

* `cap/artifact-ingest/main/...`

Canonical retained truth remains under:

* `state/update/...`
* `state/workflow/...`

### 19.5 Ryan's GSM tree

Provider-native host modem interfaces exposed directly as public capabilities SHOULD be reviewed and split into:

* raw provider-native interfaces under `raw/host/<source>/cap/modem/<id>/...`
* canonical GSM domain truth under `state/gsm/...`
* stable public semantic interfaces under `cap/...` where deliberate curation is intended (for example, `device` owning the replublishing of the raw `hal` provided capability into `modem-1`/`modem-2`)

Examples of canonical GSM retained state may include:

* `state/gsm/role/primary`
* `state/gsm/modem/modem-1`
* `state/gsm/apn/selected`
* `state/gsm/uplink/primary`

This allows the GSM service to remain the canonical owner of GSM domain truth while preserving raw provider provenance under `raw/...`.

## 20. Conclusion

The canonical Devicecode naming model is:

* `svc/...` for service lifecycle
* `cfg/...` for intended service configuration and declarative policy input
* `raw/...` for raw provenance-bearing truth and raw source-scoped interfaces
* `state/device/...` for composed appliance truth
* `state/workflow/...` for retained workflow records
* `state/<domain>/...` for canonical retained domain truth
* `cap/...` for stable public interfaces
* `obs/v1/...` for observability

Within this model:

* services remain implementation boundaries
* HAL remains the only OS and hardware boundary
* `device` is the authoritative appliance composition service
* raw sources preserve provenance
* curated and raw interfaces remain structurally segregated
* workflows are managed through stable public interfaces and recorded as workflow instances
* canonical retained domain truth is allowed where a domain service genuinely owns it
* `state/<domain>` names semantic public domains, not service ids
* durable intended behaviour is expressed declaratively by default
* immediate controls remain narrow and explicit
* component ids remain distinct from role ids
* identifier scope and stability are explicit rather than assumed
* canonical, summary and compatibility surfaces remain distinct
* and the distinction between interface contracts and canonical retained truth remains explicit
