{ pkgs, postgresql, pgstream, pgroll, major, additionalExtensions ? (_: [ ]) }:
let
  server = postgresql.withPackages (extensions: [ extensions.wal2json ] ++ additionalExtensions extensions);
  cli = pkgs.writeShellApplication {
    name = "postgres-nix";
    runtimeInputs = [ server pkgs.coreutils pkgs.findutils pkgs.gzip ];
    text = ''
      export POSTGRES_NIX_MAJOR=${pkgs.lib.escapeShellArg major}
      export POSTGRES_NIX_CONFIG=${../config}
      export POSTGRES_NIX_BOOTSTRAP=${../sql/bootstrap.sql}
    '' + builtins.readFile ../scripts/postgres-nix.sh;
  };
in pkgs.symlinkJoin {
  name = "postgres-nix-${postgresql.version}";
  paths = [ server pgstream pgroll pkgs.pgcli cli ];
  postBuild = ''
    mkdir -p "$out/share/postgres-nix"
    cp -R ${../systemd} "$out/share/postgres-nix/systemd"
    cp -R ${../launchd} "$out/share/postgres-nix/launchd"
  '';
  meta = {
    description = "PostgreSQL ${major} with portable lifecycle and backup commands";
    platforms = pkgs.lib.platforms.linux ++ pkgs.lib.platforms.darwin;
    license = pkgs.lib.licenses.mit;
    mainProgram = "postgres-nix";
  };
}
