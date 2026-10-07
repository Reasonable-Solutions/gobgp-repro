{
  description = "GoBGP 4.8.0 IPv6 link-local next-hop reproduction and fix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/a0374025a863d007d98e3297f6aa46cc3141c2f0";
    gobgp = {
      url = "github:osrg/gobgp/10495227d00666041c98244088b73fa80a59f86c";
      flake = false;
    };
  };

  outputs =
    { nixpkgs, gobgp, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      outputsFor =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          mkCase =
            patched:
            pkgs.buildGoModule {
              pname = "gobgp-next-hop-${if patched then "fix" else "repro"}";
              version = "4.8.0";
              src = gobgp;
              vendorHash = "sha256-9r8LZlCF4sr8VTyJfDktjhk32afc8ep7GXtqxUnAleE=";
              patches = pkgs.lib.optional patched ./preserve-link-local-next-hop.patch;
              postPatch = ''
                cp ${./next_hop_test.go} internal/pkg/table/sokk_next_hop_test.go
              '';
              env.CGO_ENABLED = 1;
              doCheck = false; # Both expected-failure and passing checks run below.
              buildPhase = ''
                runHook preBuild
                mkdir -p evidence bin
              ''
              + (
                if patched then
                  ''
                    go test -v ./internal/pkg/table -count=1 > evidence/tests.log 2>&1 || {
                      cat evidence/tests.log
                      exit 1
                    }
                    go build -o bin/gobgp ./cmd/gobgp
                    go build -o bin/gobgpd ./cmd/gobgpd
                    echo 'PASS: fixed GoBGP preserves both next hops; routing-table suite passed.' | tee evidence/result
                  ''
                else
                  ''
                    # This derivation succeeds only when the specific regression is
                    # reproduced. A compiler error or unrelated failure is not proof.
                    if go test -v ./internal/pkg/table -run '^TestSOKKReceivedIPv6NextHops$' -count=1 > evidence/tests.log 2>&1; then
                      cat evidence/tests.log
                      echo 'Expected the stock GoBGP regression to fail' >&2
                      exit 1
                    fi
                    cat evidence/tests.log
                    grep -Fq -- '--- PASS: TestSOKKReceivedIPv6NextHops/global-only' evidence/tests.log
                    grep -Fq -- '--- FAIL: TestSOKKReceivedIPv6NextHops/global-and-link-local' evidence/tests.log
                    test "$(grep -Fc 'lost link-local next hop:' evidence/tests.log)" -eq 2
                    echo 'REPRODUCED: stock GoBGP drops the link-local next hop for both received prefixes.' | tee evidence/result
                  ''
              )
              + ''
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                mkdir -p $out
                cp evidence/* $out/
                cp ${./next_hop_test.go} $out/next_hop_test.go
                cp ${./preserve-link-local-next-hop.patch} $out/preserve-link-local-next-hop.patch
                ${pkgs.lib.optionalString patched "cp -r bin $out/"}
                runHook postInstall
              '';
            };
        in
        {
          repro = mkCase false;
          fix = mkCase true;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          cases = outputsFor system;
        in
        cases // { default = cases.fix; }
      );
      checks = forAllSystems outputsFor;
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.go
              pkgs.nixfmt
            ];
          };
        }
      );
    };
}
