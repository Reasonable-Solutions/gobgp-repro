# GoBGP drops the IPv6 link-local next hop in `ProcessMessage`

An IPv6 MP_REACH_NLRI update can arrive with both a global and a link-local
next hop, decode correctly, and lose the link-local address when
`table.ProcessMessage` splits the update into per-prefix paths. This repository
provides a wire-format regression test and a one-line patch that preserves both
addresses.

Confirmed with **GoBGP v4.8.0**, commit
[`10495227d00666041c98244088b73fa80a59f86c`](https://github.com/osrg/gobgp/tree/10495227d00666041c98244088b73fa80a59f86c).
The flake pins that source and the build dependencies. Other GoBGP releases have
not been evaluated by this reproduction.

## Why this matters

We found this while testing an IPv6-only, unnumbered eBGP fabric with SONiC
switches and Talos 1.14.1 nodes. Hosts use stable loopback addresses for identity
and link-local peers on their physical uplinks, so moving a cable or replacing a
NIC does not require changing the host's address or switch-port assignments.

SONiC's updates contained both next hops. Talos's
[`PathNexthop`](https://github.com/siderolabs/talos/blob/2f86b9d2a29b413deddd7122a8420b8913813615/internal/app/machined/pkg/controllers/network/internal/bgp/bgp.go)
prefers the link-local address when it is present, but GoBGP had already dropped
it. Talos therefore selected the global next hop instead. In that environment,
we observed route-controller `EEXIST` errors, backoff, and failure to recover
traffic within our 30-second worker-uplink failure budget.

The library defect is independently reproducible: a received next-hop field is
lost during path conversion. Reproducing it does not require Talos, SONiC, VMs,
a running BGP session, or privileged networking.

## What goes wrong

The test sends one serialized IPv6 MP_REACH update through
`bgp.ParseBGPMessage` and then `table.ProcessMessage`. The update carries:

- Global next hop: `2001:db8::1`.
- Link-local next hop: `fe80::1`.
- Two prefixes: `::/0` and `2001:db8:51::1/128`.

Both resulting paths should retain both next hops. In unpatched v4.8.0, both
retain the global address but have an invalid/absent `LinkLocalNexthop`:

```text
lost link-local next hop: ::/0: got invalid IP, want fe80::1
lost link-local next hop: 2001:db8:51::1/128: got invalid IP, want fe80::1
```

The loss occurs in
[`internal/pkg/table/table_manager.go`](https://github.com/osrg/gobgp/blob/10495227d00666041c98244088b73fa80a59f86c/internal/pkg/table/table_manager.go#L95-L108).
`ProcessMessage` rebuilds MP_REACH attributes with one NLRI per path, but passes
only `reach.Nexthop` to the constructor. It omits the already-decoded
`reach.LinkLocalNexthop`.

## The fix and why it is appropriate

[The patch](preserve-link-local-next-hop.patch) forwards the second field to the
existing variadic constructor:

```diff
- nlriAttr, _ := bgp.NewPathAttributeMpReachNLRI(family, []bgp.PathNLRI{nlri}, nexthop)
+ nlriAttr, _ := bgp.NewPathAttributeMpReachNLRI(family, []bgp.PathNLRI{nlri}, nexthop, reach.LinkLocalNexthop)
```

This preserves information from the received update while keeping the existing
one-NLRI-per-path representation. It does not invent a next hop, replace the
global address, or impose Talos's next-hop preference on other consumers.

[`NewPathAttributeMpReachNLRI`](https://github.com/osrg/gobgp/blob/10495227d00666041c98244088b73fa80a59f86c/pkg/packet/bgp/bgp.go#L13069-L13130)
already accepts the optional link-local address and accounts for it in the
attribute length. It includes the second address only when it is valid and
link-local. Passing an absent address therefore preserves global-only behavior;
there is no need for another encoder or a special-case downstream workaround.
The patch leaves the existing withdrawal handling in place.

[The regression test](next_hop_test.go) covers both global-only and
global-plus-link-local updates, checking every resulting path. The global-only
control passes before and after the patch. The dual-address case fails for both
prefixes before the patch and passes afterward. The fixed build also runs the
entire `internal/pkg/table` test suite.

## Reproduce and verify with Nix

Use Linux with Nix and flakes enabled. From a checkout of this repository:

```sh
nix build .#repro -o result-repro -L
cat result-repro/result
cat result-repro/tests.log

nix build .#fix -o result-fix -L
cat result-fix/result
cat result-fix/tests.log

nix flake check -L
```

**A successful `repro` build means the bug was reproduced.** It succeeds only
when the global-only control passes and the dual-address case produces both
expected missing-next-hop failures. Compiler errors or unrelated failures do
not count. Its result is:

```text
REPRODUCED: stock GoBGP drops the link-local next hop for both received prefixes.
```

The `fix` output applies the patch, requires the full routing-table suite to
pass, and builds patched `bin/gobgp` and `bin/gobgpd`. Its result is:

```text
PASS: fixed GoBGP preserves both next hops; routing-table suite passed.
```

Both outputs retain `tests.log`, the regression test, and the patch. The default
package is `fix`. Initial builds fetch pinned sources and dependencies; tests
run in the build sandbox without network access. Validation was performed on
x86_64 Linux; aarch64 Linux outputs are defined but have not been validated.

## Run the test in a GoBGP checkout

For maintainers who already have a v4.8.0 source checkout and its Go/C build
toolchain, copy the test into the internal package so it can exercise
`ProcessMessage` directly. Run these commands from the GoBGP source root:

```sh
repro_dir=/path/to/gobgp-repro
cp "$repro_dir/next_hop_test.go" internal/pkg/table/sokk_next_hop_test.go

# Expected to fail with the two missing-link-local errors shown above.
go test -v ./internal/pkg/table -run '^TestSOKKReceivedIPv6NextHops$' -count=1

patch -p1 < "$repro_dir/preserve-link-local-next-hop.patch"

# Expected to pass, including the new regression test.
go test -v ./internal/pkg/table -count=1
```

## Additional integration evidence and scope

Separately from this standalone reproduction, we rebuilt Talos 1.14.1 with the
patch and ran a cold-start KVM lab with two routers, two SONiC VS switches, three
control planes, and three workers. All six nodes verified the patched version
before and after installation. Live routes used link-local gateways, and all
26 acceptance cases passed, including cable moves, NIC replacement, uplink
failures, and switch/router/node power recovery. The previously failing worker
uplink case completed in 5.5 seconds; the cable-move case completed in 21.5
seconds. Those are complete case durations, not measured outage durations.

That is supporting integration evidence, not a test executed by this flake.
This repository builds GoBGP only. The patch addresses this receive-conversion
site; it does not establish that every next-hop conversion elsewhere in GoBGP
is lossless, and virtual-switch testing does not qualify physical ASIC behavior.
