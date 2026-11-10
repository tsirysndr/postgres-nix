{
  description = "Versioned PostgreSQL runtimes for Linux and macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Unstable dropped Intel macOS; retain its supported toolchain explicitly.
  inputs.nixpkgs-intel-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

  outputs = { self, nixpkgs, nixpkgs-intel-darwin }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system:
        if system == "x86_64-darwin" then
          let base = import nixpkgs-intel-darwin { inherit system; };
          in base // {
            # Reuse the pinned current PostgreSQL recipe with the Intel toolchain.
            postgresql_19 = base.callPackage
              "${nixpkgs}/pkgs/servers/sql/postgresql/generic.nix"
              ((import "${nixpkgs}/pkgs/servers/sql/postgresql/19.nix") // {
                self = base;
                jitSupport = false;
              });
          }
        else import nixpkgs { inherit system; };
      packagesFor = system:
        let
          pkgs = pkgsFor system;
          pgstream = import ./nix/pgstream.nix { inherit pkgs; };
          versions = builtins.filter
            (name: builtins.match "postgresql_[0-9]+" name != null
              && (builtins.tryEval pkgs.${name}.version).success)
            (builtins.attrNames pkgs);
          runtimes = builtins.listToAttrs (map (name:
            let major = nixpkgs.lib.removePrefix "postgresql_" name;
            in {
              name = "postgres${major}";
              value = import ./nix/runtime.nix {
                inherit pkgs major pgstream;
                postgresql = pkgs.${name};
              };
            }) versions);
        in runtimes // { inherit pgstream; default = runtimes.postgres18; };
    in {
      packages = forAllSystems packagesFor;
      apps = forAllSystems (system:
        builtins.mapAttrs (name: package: {
          type = "app";
          program = "${package}/bin/${if name == "pgstream" then "pgstream" else "postgres-nix"}";
          meta.description = package.meta.description;
        }) self.packages.${system});
      devShells = forAllSystems (system:
        builtins.mapAttrs (_: package:
          let pkgs = pkgsFor system;
          in pkgs.mkShell { packages = [ package ]; }
        ) self.packages.${system});
      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
      checks = forAllSystems (system:
        let pkgs = pkgsFor system;
        in builtins.listToAttrs (map (version: {
          name = "smoke-${version}";
          value = pkgs.runCommand "postgres-nix-smoke-${version}" {
            nativeBuildInputs = [ self.packages.${system}.${version} pkgs.gzip ];
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            export PGPORT=55432
            export PGHOST="$TMPDIR/socket"
            export PGDATA="$TMPDIR/cluster"
            export PG_CONFIG_DIR="$TMPDIR/config"
            export PG_BACKUP_DIR="$TMPDIR/backups"
            export PG_LISTEN_ADDRESSES=""
            pgstream --help >/dev/null
            bash ${./tests/smoke.sh}
            touch "$out"
          '';
        }) [ "postgres18" "postgres19" ]));
    };
}
