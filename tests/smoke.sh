set -euo pipefail
postgres-nix init
postgres-nix start > "$TMPDIR/postgres.log" 2>&1 &
server_pid=$!
cleanup() {
  postgres-nix stop || true
  wait "$server_pid" || true
  cat "$TMPDIR/postgres.log"
}
trap cleanup EXIT
ready=false
for _ in {1..60}; do
  if postgres-nix health; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]]
postgres-nix provision
postgres-nix provision # Provisioning must be safe to rerun.
postgres-nix psql -d app <<'SQL'
SET ROLE app_owner;
CREATE TABLE smoke (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, value text);
RESET ROLE;
SET ROLE app;
INSERT INTO smoke(value) VALUES ('round-trip');
SELECT * FROM smoke;
DO $$ BEGIN
  IF has_database_privilege('app', 'app', 'CREATE') THEN
    RAISE EXCEPTION 'runtime role must not create schemas';
  END IF;
END $$;
SQL
[[ "$(postgres-nix psql -Atc "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL")" == 0 ]]
[[ "$(postgres-nix psql -Atc "SHOW data_checksums")" == on ]]
# Exercise the output plugin required by pgstream, against this server major.
postgres-nix stop
wait "$server_pid"
printf '\nwal_level = logical\n' > "$PG_CONFIG_DIR/local.conf"
postgres-nix start >> "$TMPDIR/postgres.log" 2>&1 &
server_pid=$!
for _ in {1..60}; do
  if postgres-nix health; then break; fi
  sleep 1
done
postgres-nix psql -c "SELECT * FROM pg_create_logical_replication_slot('smoke', 'wal2json')"
postgres-nix psql -c "SELECT pg_drop_replication_slot('smoke')"
dump="$(postgres-nix backup)"
gzip -t "$dump"
if postgres-nix init; then echo 'Unexpected reinitialization' >&2; exit 1; fi
postgres-nix stop
wait "$server_pid"
# Restore into a second fresh cluster, using the same socket/port after shutdown.
export PGDATA="$TMPDIR/restored/data"
export PG_CONFIG_DIR="$TMPDIR/restored/config"
postgres-nix init
postgres-nix start >> "$TMPDIR/postgres.log" 2>&1 &
server_pid=$!
ready=false
for _ in {1..60}; do
  if postgres-nix health; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]]
# pg_dumpall includes CREATE ROLE postgres, which already exists on a fresh cluster.
# Remove only that known statement; fail on every other SQL error.
gzip -dc "$dump" | sed '/^CREATE ROLE postgres;$/d' | postgres-nix psql
[[ "$(postgres-nix psql -d app -Atc 'SELECT value FROM smoke')" == round-trip ]]
