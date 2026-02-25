You can get to “fast to boot, cheap to adjust, scales to /20” if you stop thinking in terms of “tc rules per possible host” and instead treat shaping as:

1. a *fixed* dataplane (qdiscs/classes/filters) that is created once per interface; and
2. a small, mutable *control plane* (maps and a bounded set of per-active-user classes) that you update incrementally.

Below is a plan that fits your constraints and keeps the expensive work out of the steady state.

---

## 1. LAN per-user shaping: fixed dataplane, map-driven classification

### 1.1 What you actually need on a LAN

For each LAN “network” (bridge or routed interface) you want, per active user/IP:

* **download cap** (router → client): classify by *destination IP* on the LAN egress device
* **upload cap** (client → router): classify by *source IP* on LAN ingress, made shapeable via IFB

That implies:

* `br-lan` (or `br-<id>`) **egress**: HTB classes keyed by `dst_ip`
* `ifb-br-lan` **egress** (fed from `br-lan` ingress): HTB classes keyed by `src_ip`
* fq_codel at the leaves for latency control

### 1.2 Avoid per-IP tc filters

The expensive bit in your old approach is not HTB; it is *thousands of tc filters* and rebuilding trees.

Instead, use a **single classifier** that does a lookup in a kernel map:

* key: IPv4 address (src or dst)
* value: “user class handle” (or an index that maps to a class handle)

Then the number of `tc filter` rules becomes **O(1)** per direction, regardless of subnet size (/20, /16, etc). You only vary:

* the map entries (as users come/go), and
* the parameters of a bounded set of classes.

There are two practical ways to do the “map lookup” on Linux/OpenWrt:

**Option A (most straightforward operationally): nftables maps + tc fw classifier**

* Use nft to set `skb->mark` based on `ip saddr/daddr` membership in an nft map.
* Then a single `tc filter fw` maps mark → classid.
* Updating policy becomes: update nft map entries (cheap; batchable).

**Option B (highest performance): tc eBPF classifier with a BPF map**

* A tc BPF program reads IPv4 src/dst and looks up a pinned BPF map.
* It sets classid/priority accordingly.
* Updating policy becomes: update BPF map entries (very cheap, but more moving parts).

Given you are on OpenWrt and want a pragmatic bring-up path, Option A is usually the right first step. Option B can come later if you need even lower CPU overhead.

### 1.3 HTB structure: bounded classes, not “one per address”

You can choose to have:

* **one class per active *IP*** (simple), or
* **one class per active *user*** and map multiple IPs to it (better long-term).

Either way, keep a **fixed upper bound** on the number of classes you will create per LAN (e.g. 512 or 2048). With a /20 you may have 4096 potential hosts, but the number of *active* clients is usually far smaller; and if it is not, you should still have a firm cap with an eviction policy.

Suggested structure per direction:

* root `1:` HTB
* class `1:1` (parent, “all shaped traffic”)
* class `1:ff` (default/unclassified, with fq_codel; used when no per-user rule exists)
* class pool `1:100`..`1:8ff` (bounded pool for per-user/per-IP caps), each with fq_codel leaf

Updates are then:

* `tc class change ... classid 1:XYZ htb rate ... ceil ... burst ...`
* and a map entry update so that IP → classid

No tree rebuild. No qdisc churn. No filter churn.

### 1.4 IFB handling for upload shaping (LAN ingress)

This part remains standard:

* On `br-lan` ingress attach `clsact` (or ingress qdisc) and redirect IP traffic to `ifb-br-lan` using `mirred egress redirect`.
* Exempt traffic you do not want to shape (e.g. control plane, local services) with higher-priority “pass” filters before the redirect if required.

The key change is that the IFB egress HTB uses the *same map-driven classification* so it scales.

---

## 2. Backhaul WAN shaping: cake/fq_codel for transit, with router bypass

Your aims for WAN are slightly different:

* shape *the link* for latency and fairness (cake/fq_codel)
* but keep the router’s own speedtest traffic out of that shaping so it can measure raw capacity

### 2.1 Ingress (download) bypass is easy

If you do ingress shaping via IFB:

* only redirect packets you want shaped (typically forwarded/transit traffic)
* do **not** redirect packets destined to the router itself (speedtest downloads terminate locally)

Mechanically:

* first filter: `match ip dst <router_wan_ip>/32 action pass`
* second filter: `matchall action mirred redirect dev ifb-wan`

So your speedtest download never enters the shaping dataplane.

### 2.2 Egress (upload) bypass needs explicit classification

For router-originated uploads (speedtest), you need to steer those packets around the transit shaper.

The cleanest approach is:

* make WAN egress root an **HTB split**:

  * class A: `local` (very high / unlimited), for router-originated traffic you want to bypass
  * class B: `transit` (shaped), for forwarded traffic and everything else
* attach **cake** (or fq_codel) *as a child qdisc on the transit class*
* classify speedtest flows into `local` via a mark set by nft (match on UID, cgroup, DSCP, or fwmark from the speedtest helper)

Then adjusting “link bandwidth” becomes:

* update transit class rate/ceil (one `tc class change`)
* optionally also update cake’s `bandwidth` parameter to match (one `tc qdisc change`)

This gives you:

* correct link shaping for transit
* router bypass for measurement traffic
* very cheap bandwidth retuning at runtime

If you prefer to keep cake as root qdisc, you lose true bypass (everything shares the same bandwidth cap), so the HTB split is the more coherent design for your stated goal.

---

## 3. Make initialisation fast and updates cheap

### 3.1 Create once, then mutate

The HAL “apply” should have two modes:

* **ensure_dataplane()**: idempotently create qdiscs/classes/IFBs/redirect plumbing if missing
* **update_policy()**: only adjust:

  * class parameters (rate/ceil/burst)
  * map entries (IP → class)
  * cake bandwidth (WAN transit)

This is the single biggest lever on performance.

### 3.2 Batch everything

Even on an RPi 5, fork/exec dominates if you do it per command.

* Use `tc -batch` for tc operations.
* Use `nft -f` for nft map updates.
* Coalesce updates in HAL: apply at a fixed tick (e.g. every 200–500 ms) unless there is a “must apply now” reason.

### 3.3 Bounded “active user” model

Define what “active” means and make it explicit:

* source of truth could be dnsmasq leases + ARP/neighbour table + conntrack counters
* expire inactive mappings after N minutes
* cap the number of active classes; if exceeded:

  * evict least recently active to default class, or
  * fall back to “fairness only” class for excess clients (still bounded)

This is how you keep /20 workable without pretending you can maintain perfect per-host state for every possible address forever.

---

## 4. What NET should hand to HAL (shape intent)

NET should not be shipping command lists. It should hand HAL a compact, declarative intent such as:

* LAN `<id>`:

  * bridge dev, ifb dev
  * per-user caps: down `{rate, ceil, burst}`, up `{rate, ceil, burst}`
  * class pool size
  * classification mode: `nft_map` (and which maps)
  * exemptions (optional): router IPs, service marks

* WAN `<id>`:

  * dev, ifb dev (if ingress shaping)
  * transit shaping algo: `cake` or `fq_codel`
  * dynamic bandwidth controller inputs (your speedtest results)
  * bypass classification rule for speedtest flows

HAL then owns:

* kernel feature detection (clsact/IFB availability, nft support)
* dataplane construction
* incremental updates
* fallbacks when the platform cannot support a feature

---

## 5. A short practical recommendation

If you want the quickest route to something robust:

1. Implement LAN per-user shaping with **HTB + IFB + fq_codel**, but do classification using **nft maps + marks + one tc fw filter** per direction.
2. Implement WAN shaping with **HTB split (local vs transit)** and put **cake under the transit class**, with ingress IFB for download shaping and an explicit “do not redirect router-destined traffic” rule.
3. Make HAL apply idempotently and in batches; NET only updates policy deltas.

If you tell me whether you are already committed to nftables (vs legacy iptables), I can sketch the concrete dataplane build (tc + nft) in a way that is still readable and strictly idempotent, and show where the “map update” hooks sit so NET can drive it cheaply.
