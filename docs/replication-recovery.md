# Replication checks and recovery

Keep runtime connection strings and passwords outside the flake and Nix store.
The commands below assume an existing pgstream configuration and target database;
substitute your database, role, schema and slot names.

## Confirm that replication is advancing

Check pgstream's local status endpoint and its service logs:

```sh
curl --fail http://127.0.0.1:9910/status
systemctl --user status postgres-nix.service pgstream-xata.service
```

`status: ok` alone does not prove that a replica is caught up. Confirm the phase
is `replication`, inspect snapshot errors on the target, and sample the source
slot's confirmed position twice to establish that acknowledgements advance:

```sql
-- Latest result for each target snapshot scope. Earlier failures remain in history.
SELECT DISTINCT ON (schema_name, table_names, mode)
       schema_name, table_names, mode, status, errors IS NOT NULL AS has_errors
FROM pgstream.snapshot_requests
ORDER BY schema_name, table_names, mode, created_at DESC;

-- Source database, for the specific slots you manage:
SELECT slot_name, active, confirmed_flush_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS unacknowledged
FROM pg_replication_slots
WHERE slot_name IN ('your_replica_slot');
```

`pg_stat_user_tables.n_live_tup` estimates table rows. `n_tup_ins` records cumulative
inserts and can include rolled-back work; it is not a committed-row count.
Use `count(*)` when an exact count is needed, accounting for ongoing source writes.

## Prevent interrupted long snapshots

Source-side `statement_timeout` and `idle_in_transaction_session_timeout` can
interrupt a long-running snapshot or expire its exported transaction. A resulting
"snapshot does not exist" message is not, by itself, proof of load balancing.
Read the earlier errors first.

For pgstream's PostgreSQL driver, the source URL can carry session parameters:

```text
statement_timeout=0
options=-cidle_in_transaction_session_timeout=0
```

Merge these query parameters into the private source URL, keeping its verified
TLS settings. Probe the edited configuration with `pgstream status -c ...` before
restarting the affected service. These parameters affect new connections only;
they do not change the production role or database defaults. Removing timeouts
allows long statements, so monitor the snapshot and cancel it explicitly if needed.

Preserve the replication slot during recovery. Reconcile incomplete tables while
the consumer is stopped, retain the WAL needed to cover the backfill, then resume
and verify catch-up. Keep an audit of the tables repaired. Do not mark failed
snapshot requests successful until the replacement backfill actually completes.

## Materialized-view refresh failures

A schema-only restore leaves materialized views unpopulated. Initialize them on
the target with a normal, schema-qualified refresh after their base tables have
been copied. Concurrent refreshes require populated views and suitable indexes.

```sql
SELECT schemaname, matviewname, ispopulated FROM pg_matviews;
REFRESH MATERIALIZED VIEW your_schema.your_view;
```

Replayed concurrent DDL may execute on the target connection's default search
path. If the source uses unqualified names, configure the replica writer's search
path for that database to include the trusted source schema. For example:

```sql
ALTER ROLE replica_writer IN DATABASE replica_database
SET search_path TO public, your_schema;
```

Reconnect the writer so its new sessions pick up this setting. Resolve ambiguous
names explicitly when multiple schemas contain objects with the same name.

Keep materialized views out of wal2json's row stream with the replication plugin's
`filter_tables` option, listing their schema-qualified names. Their contents are
maintained by replaying the refresh DDL. This avoids tuple-identity warnings for
materialized-view deletes.

For a large historical backlog, repeated view refreshes can dominate replay
time. After comparing source and target view definitions, an operator can
temporarily exclude the `materialized_views` DDL category, continue replaying
base-table changes, then refresh the target views after catch-up and restore the
original DDL filter. Recheck definitions before restoring normal replay. Keep
this transition in a supervised recovery job so it completes after disconnection.

## Physical recovery backups

For a long physical-backup transfer, collect the required WAL alongside the data:

```sh
pg_basebackup --pgdata="$HOME/postgres-backup" --format=plain --wal-method=stream
pg_verifybackup "$HOME/postgres-backup"
```

Transfer the completed backup and verify it again on the destination before
activating it. The `fetch` WAL method depends on the source retaining all required
segments until the backup finishes. An interrupted or failed backup must pass
verification before it can replace a running cluster. Preserve the previous
cluster and device-specific access settings during a recovery.

## Legacy NOT VALID checks

PostgreSQL still enforces a `NOT VALID` check for newly inserted or updated rows.
Legacy source rows can therefore fail a target backfill. Preserve the original
constraint definitions before deferring any affected checks on the target, and
restore those checks as `NOT VALID` after the backfill. This does not validate or
repair the source's legacy rows. Do not disable unrelated constraints or suppress
replication errors to make the pipeline appear healthy.

## Reboot persistence

Enable both user services and user lingering, so they start without an SSH login:

```sh
systemctl --user enable postgres-nix.service pgstream-xata.service
loginctl show-user "$USER" -p Linger
```

An administrator can enable lingering with `loginctl enable-linger USER` if needed.
Keep the target data directory, private runtime configuration and Nix profile on
persistent storage. After a reboot, repeat the phase, snapshot and slot checks.
