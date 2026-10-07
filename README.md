# GoBGP IPv6 next-hop reproduction

This project pins GoBGP **v4.8.0**, commit
`10495227d00666041c98244088b73fa80a59f86c`, and the Nix toolchain.
It reproduces the loss of an IPv6 link-local next hop in `table.ProcessMessage`
and checks a one-line fix. No VMs, KVM, Talos cluster or network privileges are
needed. Nix fetches pinned sources/dependencies on the first build; tests run
inside the build sandbox without network access.

```sh
nix build .#repro -o result-repro -L
cat result-repro/result
cat result-repro/tests.log

nix build .#fix -o result-fix -L
cat result-fix/result
./result-fix/bin/gobgpd --version

nix flake check -L
```

`repro` is an **expected-failure assertion**: its Nix build succeeds only when
the unpatched regression test fails with both expected missing-next-hop errors
and its global-only control passes. An unrelated build failure is not accepted
as a reproduction. `fix` applies `preserve-link-local-next-hop.patch`, runs the
entire routing-table test suite including the regression, and builds patched
`gobgp` and `gobgpd` binaries. Both outputs retain the test log, patch and test
source. The default package is `fix`.

The test serializes and decodes one IPv6 MP_REACH update carrying a default
route and a host route, then converts it through `ProcessMessage`. It checks
that every resulting path retains both global and link-local next hops. The
stock implementation decodes both but reconstructs each path with only the
global address. The patch passes the decoded link-local address to the existing
variadic constructor as well; an absent link-local address remains absent.

The patch targets the receive conversion only. It is a candidate upstream fix,
not a rebuilt Talos image or proof of end-to-end fabric recovery. No upstream
issue or pull request is submitted by this project.

For edits, use `nix develop`, `gofmt -w next_hop_test.go`, and `nix fmt -- flake.nix`.
Linux x86_64 and aarch64 outputs are defined; validation was performed on x86_64.

Upstream source: <https://github.com/osrg/gobgp/tree/10495227d00666041c98244088b73fa80a59f86c>.
Tracked in Nits Work: `01a11827-20b1-7232-87e0-322aca13475c`.
