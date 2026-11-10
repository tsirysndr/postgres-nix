# Included by writeShellApplication, which supplies Bash, strict mode and PATH.
umask 077
export PGDATA="${PGDATA:-${XDG_DATA_HOME:-$HOME/.local/share}/postgres-nix/$POSTGRES_NIX_MAJOR/data}"
PG_CONFIG_DIR="${PG_CONFIG_DIR:-$(dirname "$PGDATA")/config}"
PGHOST="${PGHOST:-$(dirname "$PGDATA")/run}"
export PG_CONFIG_DIR PGHOST
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-postgres}"
PG_BACKUP_DIR="${PG_BACKUP_DIR:-$(dirname "$PGDATA")/backups}"
export PG_BACKUP_DIR

die() { echo "postgres-nix: $*" >&2; exit 1; }
check_cluster() {
  [[ -f "$PGDATA/PG_VERSION" ]] || die "No cluster at $PGDATA; run init explicitly or restore the data volume."
  [[ "$(cat "$PGDATA/PG_VERSION")" == "$POSTGRES_NIX_MAJOR" ]] || die "Cluster major differs from selected PostgreSQL $POSTGRES_NIX_MAJOR; use pg_upgrade or dump/restore."
}
check_socket() {
  [[ "$PGHOST" == /* ]] || die "PGHOST must be an absolute Unix socket directory for this command."
}

command="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi
case "$command" in
  init)
    [[ $# == 0 ]] || die "init takes no arguments; configure paths through PGDATA and PG_CONFIG_DIR."
    check_socket
    [[ ! -e "$PGDATA/PG_VERSION" ]] || die "Cluster already exists at $PGDATA."
    if [[ -d "$PGDATA" && -n "$(find "$PGDATA" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      die "Refusing to initialize a nonempty data directory."
    fi
    mkdir -p "$PG_CONFIG_DIR" "$PGHOST"
    chmod 700 "$PGHOST"
    for file in postgresql.conf pg_hba.conf; do
      if [[ ! -e "$PG_CONFIG_DIR/$file" ]]; then
        cp "$POSTGRES_NIX_CONFIG/$file" "$PG_CONFIG_DIR/$file"
        chmod 600 "$PG_CONFIG_DIR/$file"
      fi
    done
    if [[ ! -e "$PG_CONFIG_DIR/pg_ident.conf" ]]; then
      owner="$(id -un)"
      [[ "$owner" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "Unsupported OS account name for the admin peer map."
      printf 'owner %s postgres\n' "$owner" > "$PG_CONFIG_DIR/pg_ident.conf"
      chmod 600 "$PG_CONFIG_DIR/pg_ident.conf"
    fi
    initdb -D "$PGDATA" --username=postgres --encoding=UTF8 --locale=C \
      --auth-local=peer --auth-host=scram-sha-256 --data-checksums
    echo "Initialized PostgreSQL $POSTGRES_NIX_MAJOR at $PGDATA. Start with: postgres-nix start"
    ;;
  start)
    check_cluster
    check_socket
    [[ -r "$PG_CONFIG_DIR/postgresql.conf" && -r "$PG_CONFIG_DIR/pg_hba.conf" && -r "$PG_CONFIG_DIR/pg_ident.conf" ]] || die "Missing configuration in $PG_CONFIG_DIR."
    mkdir -p "$PGHOST"
    chmod 700 "$PGHOST"
    exec postgres -D "$PGDATA" \
      -c "config_file=$PG_CONFIG_DIR/postgresql.conf" \
      -c "hba_file=$PG_CONFIG_DIR/pg_hba.conf" \
      -c "ident_file=$PG_CONFIG_DIR/pg_ident.conf" \
      -c "unix_socket_directories=$PGHOST" -c "port=$PGPORT" \
      -c "listen_addresses=${PG_LISTEN_ADDRESSES-127.0.0.1,::1}" "$@"
    ;;
  stop)
    check_cluster
    exec pg_ctl -D "$PGDATA" -m fast -w -t 120 stop "$@"
    ;;
  reload)
    check_cluster
    exec pg_ctl -D "$PGDATA" reload "$@"
    ;;
  psql)
    exec psql -X --set=ON_ERROR_STOP=1 "$@"
    ;;
  health)
    # An authenticated query detects more failures than pg_isready alone.
    exec psql -X --set=ON_ERROR_STOP=1 --tuples-only --no-align -c 'SELECT 1' "$@"
    ;;
  provision)
    check_socket
    exec psql -X --set=ON_ERROR_STOP=1 --file="$POSTGRES_NIX_BOOTSTRAP" "$@"
    ;;
  backup)
    check_socket
    [[ $# == 0 ]] || die "backup takes no arguments."
    retention="${PG_BACKUP_RETENTION_DAYS:-14}"
    [[ "$retention" =~ ^[1-9][0-9]*$ ]] || die "PG_BACKUP_RETENTION_DAYS must be a positive integer."
    mkdir -p "$PG_BACKUP_DIR"
    chmod 700 "$PG_BACKUP_DIR"
    # Unique filenames also make concurrent manual backups safe.
    tmp="$(mktemp "$PG_BACKUP_DIR/.incomplete-XXXXXXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    pg_dumpall --no-role-passwords | gzip -6 > "$tmp"
    gzip -t "$tmp"
    final="$PG_BACKUP_DIR/cluster-$(date -u +%Y%m%dT%H%M%SZ)-${tmp##*/}.sql.gz"
    mv "$tmp" "$final"
    trap - EXIT
    # Prune only completed files after a successful dump; failed dumps retain history.
    find "$PG_BACKUP_DIR" -type f -name 'cluster-*.sql.gz' -mtime "+$retention" -delete
    echo "$final"
    ;;
  version)
    exec postgres --version
    ;;
  help|-h|--help)
    cat <<'HELP'
Usage: postgres-nix <init|start|stop|reload|psql|health|provision|backup|version>

init       Explicitly create a checksummed cluster and copy default config.
start      Run PostgreSQL in the foreground (for systemd/launchd).
stop       Fast, clean shutdown, waiting up to 120 seconds.
reload     Reload configuration without restarting.
psql       Open a session; additional arguments go to psql.
health     Execute an authenticated SELECT 1.
provision  Create app, app_owner and app_migrator roles and the app database.
backup     Atomically write a compressed cluster dump; keep 14 days by default.
version    Show the packaged PostgreSQL version.

Environment: PGDATA, PG_CONFIG_DIR, PGHOST (socket directory), PGPORT,
PGUSER, PGDATABASE, PG_BACKUP_DIR, PG_BACKUP_RETENTION_DAYS,
PG_LISTEN_ADDRESSES (startup only, defaults to loopback).
Use the same environment and OS account for every lifecycle command.
HELP
    ;;
  *) die "Unknown command: $command (see postgres-nix help)" ;;
esac
