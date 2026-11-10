# postgres-nix

[![Nix build and checks](https://github.com/tsirysndr/postgres-nix/actions/workflows/check.yml/badge.svg)](https://github.com/tsirysndr/postgres-nix/actions/workflows/check.yml)

Versioned PostgreSQL runtimes with a Nix flake, for **x86_64-linux**,
**aarch64-linux**, **x86_64-darwin**, and **aarch64-darwin**. No NixOS required.
Includes server/client tools, the `wal2json` output plugin, and
[pgstream](https://github.com/xataio/pgstream) for change data capture.

The default is PostgreSQL **18.6**, pinned by `flake.lock`. PostgreSQL **19rc1**
is available explicitly for testing; it is not a production release. Check the
[upstream releases](https://www.postgresql.org/docs/release/) before upgrading.
Other PostgreSQL majors present in the pinned nixpkgs are exposed automatically.

This is a single-server production baseline: checksums, durable writes, restricted
authentication, separate application/migration roles, supervised service templates,
and daily logical backups. Configure off-host backups, monitoring, capacity, TLS
for remote clients, and your required recovery objectives before accepting traffic.
It does not configure HA, automatic failover, or continuous WAL archival/PITR.

## Choose a version

Install Nix with flakes enabled. Run these commands in this repository:

If the repository has not been committed yet, use `path:.#postgres18` in place of
`.#postgres18` (and likewise for other outputs), or stage the new files first.
Nix's Git flake source excludes untracked files.

```sh
nix run .#postgres18 -- version
nix run .#postgres19 -- version
nix run .#pgstream -- --version
nix develop .#postgres18
# The shell includes postgres-nix, psql, pg_dump, pg_upgrade, and pgstream.
```

Use `.#postgres18`, `.#postgres19`, etc. consistently when selecting a runtime;
`.#default` is deliberately fixed to major 18. A lock-file update updates minor
releases, not the default major. Future majors become available when added to
nixpkgs; change the default deliberately after testing an upgrade.

Nix may download or build missing packages for `nix run`/`nix develop`. To avoid
local builds, build on the destination host or a configured remote builder. The
build commands below are deployment instructions, not commands run as part of
setting up this repository.

For another flake, add this repository as a locked input and select a package:

```nix
inputs.postgres-nix.url = "git+https://YOUR_REPOSITORY_URL";
# In outputs, for the desired system:
# postgres-nix.packages.${system}.postgres18
# postgres-nix.packages.${system}.postgres19
# postgres-nix.packages.${system}.pgstream
```

## First cluster on Linux or macOS

Run as a normal user, never root. Start the database in one terminal:

```sh
nix develop .#postgres18
postgres-nix init
postgres-nix start
```

In another terminal, enter the same shell and provision the application:

```sh
nix develop .#postgres18
postgres-nix health
postgres-nix provision
postgres-nix psql
```

At the `psql` prompt, set two different strong passwords interactively:

```text
\password app
\password app_migrator
\q
```

No password is set initially: TCP password login cannot succeed until you set it.
`\password` keeps the cleartext secret out of shell history and SQL command text.
Do not put passwords in flakes, command-line URLs, committed `.env` files, or the
Nix store. Use a runtime secret manager or a `0600` application credential file.

Defaults (major 18 shown):

| Variable | Default | Purpose |
| --- | --- | --- |
| `PGDATA` | `$HOME/.local/share/postgres-nix/18/data` | Persistent cluster data (`XDG_DATA_HOME` is respected) |
| `PG_CONFIG_DIR` | Sibling `config` directory | Mutable configuration outside the Nix store |
| `PGHOST` | Sibling `run` directory | Private absolute Unix socket path |
| `PGPORT` | `5432` | TCP/socket port |
| `PGUSER`, `PGDATABASE` | `postgres`, `postgres` | Admin client defaults |
| `PG_BACKUP_DIR` | Sibling `backups` directory | Logical backup destination |
| `PG_BACKUP_RETENTION_DAYS` | `14` | Retention after a successful backup |
| `PG_LISTEN_ADDRESSES` | `127.0.0.1,::1` | Startup bind addresses; empty disables TCP |

Export overrides **before init** and keep the same values for every command.
For example, a separate PostgreSQL 19 test cluster uses its own data/config/socket
directories automatically, but needs `export PGPORT=5433` if 18 is already running.
Keep Unix socket paths short enough for your OS (roughly 100 bytes).

`init` refuses an existing or nonempty cluster; `start` refuses missing data and
major-version mismatches. A service restart never initializes a new cluster.
Initialization writes a peer-auth mapping from the current OS account to DB role
`postgres`, so macOS works without an OS user named `postgres`. Anyone controlling
the server's OS account controls the cluster: use a dedicated account on servers.

## Databases, users, and permissions

`postgres-nix provision` can be rerun and creates:

| Object | Purpose |
| --- | --- |
| Database `app` | Owned by `app_owner`; PUBLIC access revoked |
| Role `app_owner` | NOLOGIN owner of application objects |
| Role `app_migrator` | Login member of `app_owner`; run migrations with `SET ROLE app_owner` |
| Role `app` | Login with CONNECT, schema USAGE, table CRUD and sequence privileges |

Application roles are not superusers and cannot create databases or roles. New
tables/sequences in `public` receive runtime grants when created by `app_owner`.
The provisioning command does not reset passwords, rename objects, or remove
pre-existing privileges. Review existing roles if adopting an existing cluster.

Test application login over loopback (the socket is reserved for administration):

```sh
psql -h 127.0.0.1 -p 5432 -U app -d app -W
psql -h 127.0.0.1 -p 5432 -U app_migrator -d app -W
```

In the migration session:

```sql
SET ROLE app_owner;
CREATE TABLE public.example (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  message text NOT NULL
);
```

Your application's connection parameters are host `127.0.0.1`, port `5432`,
database `app`, user `app`, and its password. Keep migrator credentials separate.

For a different database/user, open the admin session with `postgres-nix psql`:

```sql
CREATE ROLE analytics LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE DATABASE analytics OWNER analytics;
REVOKE ALL ON DATABASE analytics FROM PUBLIC;
```

Then run `\password analytics`. Add explicit rules to `$PG_CONFIG_DIR/pg_hba.conf`:

```text
host analytics analytics 127.0.0.1/32 scram-sha-256
host analytics analytics ::1/128      scram-sha-256
```

Run `postgres-nix reload`. This simple owner/login pattern allows that account to
perform migrations; use separate owner/migrator/runtime roles as above when needed.
For custom schemas, configure schema USAGE and default privileges for that schema.

## Linux production service (systemd)

Use a Linux server with Nix installed. The following commands run **on that server**,
from a checkout of this repository. They install into a persistent Nix profile,
keeping the runtime reachable by garbage collection:

```sh
sudo nix profile add --profile /opt/postgres-nix .#postgres18
# Create a dedicated system account if one does not already exist.
getent passwd postgres || sudo useradd --system --user-group \
  --home-dir /var/lib/postgres-nix --shell /usr/sbin/nologin postgres
sudo install -d -o postgres -g postgres -m 0700 \
  /var/lib/postgres-nix/18 /etc/postgres-nix /run/postgres-nix \
  /var/backups/postgres-nix
sudo -u postgres env PGDATA=/var/lib/postgres-nix/18/data \
  PG_CONFIG_DIR=/etc/postgres-nix PGHOST=/run/postgres-nix \
  /opt/postgres-nix/bin/postgres-nix init
sudo install -m 0644 /opt/postgres-nix/share/postgres-nix/systemd/* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now postgres-nix.service
sudo -u postgres env PGHOST=/run/postgres-nix \
  /opt/postgres-nix/bin/postgres-nix provision
sudo -u postgres env PGHOST=/run/postgres-nix \
  /opt/postgres-nix/bin/postgres-nix psql
# Set \password app and \password app_migrator, then \q.
sudo systemctl enable --now postgres-nix-backup.timer
sudo systemctl start postgres-nix-backup.service
```

Reserve `/opt/postgres-nix` for this one package; use `nix profile list --profile
/opt/postgres-nix` and `nix profile upgrade --profile /opt/postgres-nix --all` for
subsequent pinned releases after updating the checkout. Restart PostgreSQL after
replacing binaries. Keep a backup and the previous profile generation for rollback.

The templates use major 18. For a **new** major-19 deployment, select `.#postgres19`
and change both systemd services' `PGDATA` to `/var/lib/postgres-nix/19/data` before
initialization. Do not point a new major at old data. Multiple simultaneous clusters
also require distinct service names, profiles, ports, sockets, configs, and backups.

The database runs unprivileged with a private socket, systemd filesystem protections,
restricted capabilities and automatic restart. SIGINT requests a fast clean shutdown.
Mount durable storage before initializing; `RequiresMountsFor` orders startup after
mounts known to systemd. Configure a required mount unit/`ConditionPathIsMountPoint`
for a dedicated database volume. Set up alerts for failed services and backups.

```sh
sudo systemctl status postgres-nix.service postgres-nix-backup.timer
sudo journalctl -u postgres-nix.service -f
sudo journalctl -u postgres-nix-backup.service
sudo -u postgres env PGHOST=/run/postgres-nix /opt/postgres-nix/bin/postgres-nix health
sudo systemctl reload postgres-nix.service
```

## macOS service (launchd)

The supplied LaunchAgent runs under your current user while logged in. For an
always-on production Mac, provision a dedicated OS account and adapt it to a
LaunchDaemon with `UserName`, persistent directories and boot-time availability.

```sh
nix profile add --profile "$HOME/.local/state/nix/profiles/postgres-nix" .#postgres18
export RUNTIME="$HOME/.local/state/nix/profiles/postgres-nix"
"$RUNTIME/bin/postgres-nix" init
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
```

Render the template using Python 3 (or replace the three placeholders manually):

```sh
python3 - <<'PY'
import os, pathlib, plistlib
home = pathlib.Path.home()
runtime = os.environ["RUNTIME"]
source = pathlib.Path(runtime) / "share/postgres-nix/launchd/app.postgres-nix.server.plist"
doc = plistlib.loads(source.read_bytes())
def render(value):
    if isinstance(value, str):
        return value.replace("@HOME@", str(home)).replace("@RUNTIME@", runtime).replace("@MAJOR@", "18")
    if isinstance(value, list): return [render(v) for v in value]
    if isinstance(value, dict): return {k: render(v) for k, v in value.items()}
    return value
target = home / "Library/LaunchAgents/app.postgres-nix.server.plist"
target.write_bytes(plistlib.dumps(render(doc)))
PY
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/app.postgres-nix.server.plist"
"$RUNTIME/bin/postgres-nix" provision
"$RUNTIME/bin/postgres-nix" psql
# Set passwords with \password as above.
```

Stop/remove the agent with `launchctl bootout "gui/$(id -u)"
"$HOME/Library/LaunchAgents/app.postgres-nix.server.plist"`. Review
`$HOME/Library/Logs/postgres-nix.log`; configure log rotation. Schedule
`$RUNTIME/bin/postgres-nix backup` with your existing scheduler using the same
environment; the Linux backup timer does not run on macOS.

Intel macOS uses a separately locked `nixpkgs-26.05-darwin` toolchain because
nixpkgs unstable dropped `x86_64-darwin`. PostgreSQL 19 reuses the pinned unstable
PostgreSQL recipe against that toolchain. Monitor the branch's security support
window and plan a supported-platform migration when it ends.

## Configuration and remote TLS

`init` copies configuration once. Repository changes do not overwrite live config;
review and apply updates explicitly. Add overrides to `$PG_CONFIG_DIR/local.conf`.
Tune RAM, connections, autovacuum and timeouts using your workload. Memory settings
are conservative starting values, not automatic sizing. Avoid `ALTER SYSTEM` for
settings managed here. Startup paths, socket, port and listen addresses are command
line settings and require the corresponding environment to change them.

TCP binds to loopback by default. To allow a remote application:

1. Set `PG_LISTEN_ADDRESSES` to the server's private IP in the supervisor environment.
2. Install a trusted TLS certificate/key as runtime files readable by the service
   account; the key must be `0600`. Add to `local.conf`:

   ```text
   ssl = on
   ssl_min_protocol_version = 'TLSv1.2'
   ssl_cert_file = '/etc/postgres-nix/tls/server.crt'
   ssl_key_file = '/etc/postgres-nix/tls/server.key'
   ```

3. Append a narrow rule such as `hostssl app app 10.20.30.0/24 scram-sha-256`
   to `pg_hba.conf`. The existing superuser/replication rejection rules stay first.
4. Restrict port 5432 to the application subnet in host/network firewalls and restart
   the service. Clients should use `sslmode=verify-full` and the trusted CA.

Only application roles have loopback rules by default. TCP superuser and physical
replication access are denied. Validate config with the admin query:

```sql
SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL;
SELECT name, setting, pending_restart FROM pg_settings WHERE pending_restart;
```

## Backups and restore

```sh
postgres-nix backup
# Linux service installation: sudo systemctl start postgres-nix-backup.service
```

Backups are `pg_dumpall --no-role-passwords` piped to gzip with pipe-failure
checking, private permissions, a temporary file and atomic publication. Completed
dumps older than the retention window are removed only after a successful backup.
Backups include roles and all databases but exclude password hashes; restore
passwords from your secret manager. A cluster dump is not a single consistent
snapshot across databases. It does not include TLS files, live configuration,
replication slot state or physical backups. Preserve runtime config separately.

Copy encrypted backups off-host, monitor their age and size, and test restoration.
Daily dumps imply up to a day's data loss (plus scheduling/copy delay); configure
pgBackRest or WAL-G with continuous WAL archival for tighter recovery objectives.

Restore into a **separate, empty test cluster**, as its owning OS user. Enter the
chosen version's dev shell, and ensure your existing backup path is absolute:

```sh
export BACKUP=/absolute/path/to/cluster-backup.sql.gz
export PGDATA="$HOME/restore-test/18/data"
export PG_CONFIG_DIR="$HOME/restore-test/18/config"
export PGHOST="$HOME/restore-test/18/run"
export PGPORT=55432
postgres-nix init
postgres-nix start
```

In another terminal with the **same exports** and selected runtime:

```sh
gzip -t "$BACKUP"
# Fresh initdb already created postgres. Remove only its duplicate CREATE ROLE.
gzip -dc "$BACKUP" | sed '/^CREATE ROLE postgres;$/d' | postgres-nix psql
postgres-nix psql -d app -c '\dt'
postgres-nix psql
# Reset login passwords with \password, then validate real application queries.
postgres-nix stop
```

Enable shell `pipefail` for restore pipelines (`set -o pipefail` in Bash/Zsh).
Restore only trusted dumps: SQL backups can execute code as the database superuser.
Do not restore over a live production cluster. For large clusters, use a tested
physical backup/restore strategy instead of relying on this logical workflow.

## pgstream

The flake pins **pgstream 1.6.0** using upstream release binaries and per-platform
SHA-256 hashes in `nix/pgstream.nix`. It is included in every PostgreSQL runtime,
or can be run independently:

```sh
nix run .#pgstream -- --version
nix run .#pgstream -- --help
```

The PostgreSQL runtime includes the **wal2json** output plugin pgstream needs.
The default configuration explicitly includes it in `output_plugin_libraries`,
required by the pinned PostgreSQL security releases. Existing clusters keep their
copied configuration: add `output_plugin_libraries = 'pgoutput, test_decoding, wal2json'`
to their `local.conf` and reload before using CDC. See the
[PostgreSQL 18.6 release notes](https://www.postgresql.org/docs/18/release-18-6.html).
Enable logical decoding on the **source** by adding to its `local.conf`:

```text
wal_level = logical
max_replication_slots = 10
max_wal_senders = 10
max_slot_wal_keep_size = '4GB'
```

Restart the source. Size the WAL limit for your disk and outage budget: exceeding
it can invalidate a stalled slot, requiring a new snapshot. Watch `pg_replication_slots`
and disk usage. Logical CDC is separate from disaster-recovery backups.

pgstream initialization installs DDL event triggers, which need elevated privileges.
Follow the [version-pinned pgstream tutorial](https://github.com/xataio/pgstream/blob/v1.6.0/docs/tutorials/postgres_to_postgres.md)
and [CLI documentation](https://github.com/xataio/pgstream/blob/v1.6.0/docs/cli.md)
to decide the source/target privileges for your replication mode. Do not use the
application's `app` credentials. A source account needs LOGIN, REPLICATION, access
to captured objects, and pgstream metadata permissions; setup needs an admin.
DDL application on the target may require ownership or elevated privileges too.
Do not grant permanent superuser access merely to get past a setup error.

Create dedicated roles through the private admin socket, set their passwords with
`\password`, and add explicit narrow HBA rules for their database. Logical
replication connections match the actual database name (for example `app`), not
the special physical `replication` HBA database field. The default rules do not
allow these roles. For a loopback source role named `pgstream_source`, append:

```text
host app pgstream_source 127.0.0.1/32 scram-sha-256
```

Use `hostssl` and verified TLS for remote source/target connections. Prepare a
private runtime config outside the repository:

```sh
mkdir -p "$HOME/.config/pgstream"
chmod 700 "$HOME/.config/pgstream"
cp config/pgstream.env.example "$HOME/.config/pgstream/replication.env"
chmod 600 "$HOME/.config/pgstream/replication.env"
# Edit URLs, URL-encoded passwords, source tables and target port before running.
pgstream init -c "$HOME/.config/pgstream/replication.env"
pgstream status -c "$HOME/.config/pgstream/replication.env"
pgstream run -c "$HOME/.config/pgstream/replication.env" --log-level info
```

For a local source, initialize over the private admin socket as the cluster's OS
owner, instead of enabling TCP access for the postgres superuser. For example,
with `PGHOST` exported to the source socket path:

```sh
pgstream init --postgres-url "postgres://postgres@/app?host=$PGHOST&sslmode=disable"
```

This replaces the `pgstream init -c ...` step above when the config contains
restricted runtime credentials. Run initialization with the administrative access described by upstream, then
configure runtime privileges before starting streaming. The example URLs contain
placeholders and cannot run unchanged. `sslmode=disable` in the example is for
same-host loopback only. Supervise `pgstream run` as its own service, protect its
credential file, and alert on errors, lag and WAL growth. Do not use `destroy` or
drop replication slots until you have stopped consumers and planned resnapshotting.

## Updates and verification

```sh
# Metadata update only; does not build packages.
nix flake update
nix eval .#packages.aarch64-linux.postgres18.name
nix eval .#packages.aarch64-linux.postgres19.name
```

Review/commit `flake.lock`, build and test on CI or a remote host, back up, then
roll out minor updates and restart. Never change a major by swapping binaries on
an existing data directory: plan `pg_upgrade` or dump/restore into a new cluster,
test extensions and application compatibility, analyze the restored/upgraded
databases, and retain a recovery path. Never downgrade a data directory by merely
rolling back a Nix profile.

The GitHub Actions workflow runs on pushes to `main` and all pull requests. It
uses `fluentci-io/setup-fluentci@next` and `setup-purescript@v0.2.0` to compile and
test the PureScript CI component once on Ubuntu amd64. The fully composed Wasm
artifact is passed to Ubuntu amd64, Ubuntu arm64 and macOS arm64 runners. All
setup, build, test and reporting logic lives in `.fluentci/ci/src/`, with a typed
native dependency on the pinned `setup-determinate-nix@v0.2.1` component. Its
environment stays in the same FluentCI host session, without a shell/Python
environment exporter. It runs `nix build` for PostgreSQL 18, PostgreSQL 19 and
pgstream, then exercises
PostgreSQL 18/19 initialization, startup, role grants, wal2json slot creation,
backups and restore; it also checks pgstream's CLI starts. It does not certify
end-to-end pgstream replication or production readiness for your workload.
The final step lists every executable in each built package and prints PostgreSQL
and pgstream versions in the job log and GitHub job summary. If the build succeeds,
this report runs even when a subsequent smoke check fails.

The repository is a FluentCI workspace (`fluentci.toml`) with a named `ci`
workflow and locked component dependencies. With PureScript 0.15.16, Spago 1.0.5,
Node.js 24 and FluentCI 0.17.3 installed, compile/test and stage the CI component:

```sh
fluentci install --frozen-lockfile
fluentci run --frozen-lockfile ci prepare
```

This compiles the CI module and runs ten regression tests using a host double;
it does not build Nix packages. To execute the actual pipeline on a CI/build host:

```sh
fluentci run --wasm .fluentci/ci/dist/ci.wasm check --system aarch64-linux
# Or compile from source and run the named workflow:
fluentci run --workflow ci
```

`check` installs Nix with sudo, builds packages and executes smoke checks. Run it
on the intended build host, not locally when avoiding Nix builds. Omit `--system`
to accept the current supported native platform.
To run the same checks on CI/a build host: `nix flake check --print-build-logs`.
Do not run that command locally when avoiding builds. This repository was set up
without running `nix build` locally.

## License

Repository configuration and scripts: [MIT](LICENSE). PostgreSQL and pgstream
retain their respective upstream licenses (PostgreSQL License and Apache-2.0).
