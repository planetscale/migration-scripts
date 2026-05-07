# PlanetScale Migration Helper Scripts

Migration toolkit for [pgcopydb](https://github.com/planetscale/pgcopydb) — used to migrate PostgreSQL databases to PlanetScale. These scripts run on a migration instance (EC2 or GCP Compute) that has network access to both the source PostgreSQL database and the PlanetScale target.

## Prerequisites

### Source Database

**Permissions:** The migration user needs access to all schemas and tables being migrated. For CDC migrations (`--follow`), it also needs the `REPLICATION` attribute. If you are using a dedicated migration user rather than the database owner, grant the following:

```sql
-- Create the migration user
CREATE ROLE migration_user WITH LOGIN PASSWORD 'your-strong-password' REPLICATION;

-- Connect and schema access
GRANT CONNECT ON DATABASE mydb TO migration_user;
GRANT USAGE ON SCHEMA public TO migration_user;

-- Read access to all tables and sequences
GRANT SELECT ON ALL TABLES IN SCHEMA public TO migration_user;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO migration_user;

-- For future tables created before migration starts
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO migration_user;

-- Prevent idle replication connection from being dropped during long COPY phases
ALTER ROLE migration_user SET wal_sender_timeout = 0;
```

Repeat the `GRANT USAGE`, `GRANT SELECT`, and `ALTER DEFAULT PRIVILEGES` statements for each schema being migrated.

**`fix-replica-identity.sh` permissions:** The script runs `ALTER TABLE ... REPLICA IDENTITY FULL` on the source, which requires table ownership — `SELECT` alone is not sufficient. Grant `migration_user` membership in the role(s) that own the tables so it inherits ownership privileges. First, find which owner roles are involved:

```sql
-- Find roles that own tables without a primary key or unique index
SELECT DISTINCT r.rolname AS owner_role
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_roles r ON r.oid = c.relowner
WHERE c.relkind = 'r'
  AND c.relreplident = 'd'
  AND n.nspname NOT LIKE 'pg_%'
  AND n.nspname != 'information_schema'
  AND NOT EXISTS (
    SELECT 1 FROM pg_constraint con
    WHERE con.conrelid = c.oid
      AND con.contype IN ('p', 'u')
  );
```

Then grant membership for each `owner_role` returned:

```sql
GRANT <owner_role> TO migration_user;
```

After running `fix-replica-identity.sh`, revoke the membership:

```sql
REVOKE <owner_role> FROM migration_user;
```

**Logical replication (CDC only):** Logical replication must be enabled on the source before starting a `--follow` migration. How to enable it depends on your platform:

- **Amazon RDS / Aurora:** Set `rds.logical_replication = 1` in the [parameter group](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithParamGroups.html) and reboot the instance. If you are using a custom parameter group, make sure it is associated with your instance. This change requires a reboot — it cannot be applied dynamically.

- **Google Cloud SQL:** Set the `cloudsql.logical_decoding` database flag to `on`. This requires an instance restart. You can set the flag via the [Cloud Console](https://docs.cloud.google.com/sql/docs/postgres/replication/configure-logical-replication), `gcloud`, or Terraform. If you are also using the pglogical extension, you must additionally set `cloudsql.enable_pglogical` to `on`.

- **Google AlloyDB:** Set the `alloydb.logical_decoding = on` database flag and restart the instance. See the [AlloyDB documentation](https://cloud.google.com/alloydb/docs/reference/database-flags) for details on setting database flags.

- **Supabase:** Logical replication is [enabled by default](https://supabase.com/docs/guides/database/replication) — `wal_level` is already set to `logical` and no configuration changes are needed. However, pgcopydb requires a **direct connection** (not a pooled connection). In your Supabase dashboard, go to Project Settings > Database to get the direct connection string. If your migration instance is outside Supabase's network, you will need to enable the [IPv4 add-on](https://supabase.com/docs/guides/platform/ipv4-address) to get a direct-connection-compatible hostname.

- **Self-hosted PostgreSQL:** Set `wal_level = logical` in `postgresql.conf` and restart PostgreSQL. Alternatively, use `ALTER SYSTEM SET wal_level = logical;` followed by a restart.

You can verify logical replication is enabled on any platform with:

```sql
SHOW wal_level;  -- should return 'logical'
```

### Target Database (PlanetScale)

- The target database must be created before starting the migration — pgcopydb does not create databases.
- The PlanetScale Default user has all necessary permissions built in. No additional grants are required. See [Managing Roles](https://planetscale.com/docs/postgres/connecting/roles) for details on users and roles.
- After the migration, you can tune target database settings from the PlanetScale dashboard. See [Cluster configuration parameters](https://planetscale.com/docs/postgres/cluster-configuration/parameters) for available options.
- Review the list of [supported extensions](https://planetscale.com/docs/postgres/extensions) to verify your source extensions are available on PlanetScale before migrating.

### Migration Instance

- Network access to both the source and target databases (typically deployed in the same VPC or peered network as the source).
- pgcopydb installed — built from the [PlanetScale fork](https://github.com/planetscale/pgcopydb).
- `screen` installed for running migrations in detached sessions.
- `sqlite3` installed for the monitoring scripts that read pgcopydb's internal catalogs.

## Setup

1. **Deploy these scripts** to the migration instance home directory (`~/`).

2. **Create `~/.env`** with your connection strings:

   ```bash
   export PGCOPYDB_SOURCE_PGURI='postgresql://user:pass@source-host:5432/dbname'
   export PGCOPYDB_TARGET_PGURI='postgresql://user:pass@target-host:5432/dbname'
   ```

3. **Customize `~/filters.ini`** to exclude schemas, tables, and extensions that should not be migrated. See [Filter Configuration](#filter-configuration) below.

4. **Make scripts executable:**

   ```bash
   chmod +x ~/*.sh
   ```

## Migration Workflow

### 1. Prepare

Before starting the migration, compare PostgreSQL parameters between source and target to identify differences that could affect performance. You can review and adjust target parameters in the PlanetScale dashboard — see [Cluster configuration parameters](https://planetscale.com/docs/postgres/cluster-configuration/parameters) for the full list of tunable settings. Note that many of the parameters on a PlanetScale cluster are already tuned appropriately and that copying directly from another provider may not bring benefit.

```bash
~/compare-pg-params.sh
```

Run the preflight check to validate that both databases and the migration instance are ready. This checks connectivity, WAL level, replication permissions, available slots/senders, conflicting publications, and local prerequisites:

```bash
~/preflight-check.sh
```

Fix any FAILs before proceeding. Warnings should be reviewed — particularly `wal_sender_timeout` (set to `0` for large migrations) and leftover pgcopydb state from previous attempts.

If you are running a live migration with CDC (`--follow`), fix replica identity on tables that lack a primary key:

```bash
~/fix-replica-identity.sh
```

This finds tables with default replica identity and no unique index, then sets them to `REPLICA IDENTITY FULL` on the source. You will be prompted to review and confirm before any changes are applied.

### 2. Migrate

Start the migration inside a screen session so it survives SSH disconnects:

```bash
~/start-migration-screen.sh
```

This runs `run-migration.sh` in a detached screen. To watch the live output:

```bash
screen -r migration     # attach
# Ctrl-A D              # detach (migration keeps running)
```

### 3. Monitor

Check overall migration progress (copy, indexes, constraints, vacuum) and see active operations (COPY, CREATE INDEX, VACUUM, ALTER TABLE) running on the target with their durations:

```bash
~/check-migration-status.sh
```

Once the initial copy completes and CDC is streaming, check replication progress:

```bash
~/check-cdc-status.sh
```

When `check-cdc-status.sh` reports **"CDC IS CAUGHT UP"** (apply backlog < 100 MB), you are ready for cutover.

### 4. Cut Over

1. **Stop writes** to the source database (maintenance mode, read-only, connection drain, etc.).

2. **Get the current WAL position** on the source:

   ```bash
   psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c "SELECT pg_current_wal_lsn();"
   ```

3. **Set the CDC endpoint** so pgcopydb stops after reaching that position:

   ```bash
   ~/stop-cdc.sh <LSN>
   MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/stop-cdc.sh <LSN>  # explicit dir
   ```

4. **Wait** for pgcopydb to apply all remaining changes and exit. Monitor with `check-cdc-status.sh`.

5. **Verify** data on the target using `verify-migration.sh`.

   ```bash
   ~/verify-migration.sh
   ```

6. **Switch** your application to the PlanetScale target.

### 5. Clean Up

After the migration is complete (or abandoned), clean up replication artifacts:

```bash
~/drop-replication-slots.sh              # uses default slot name "pgcopydb"
~/drop-replication-slots.sh my_slot      # custom slot name
```

This drops the replication slot on the source, the replication origin on the target, and the pgcopydb sentinel schema. **Always do this** — unconsumed replication slots cause WAL to accumulate on the source until the disk fills up.

## Recovery

If pgcopydb crashes, the instance reboots, or the migration is interrupted:

```bash
~/resume-migration.sh                                                        # uses most recent migration dir
MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/resume-migration.sh              # or specify explicitly
```

This backs up the SQLite catalog before resuming and uses `--not-consistent` to allow resuming from a mid-transaction state. The script passes `--split-tables-larger-than` to match `run-migration.sh` — pgcopydb requires catalog consistency, so the resume must use the same split value as the original run.

If the initial COPY completed successfully but CDC was interrupted, you can resume only the CDC phase without re-attempting the clone:

```bash
~/resume-cdc.sh                                                              # uses most recent migration dir
MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/resume-cdc.sh                    # or specify explicitly
```

This runs `pgcopydb follow` directly (not `clone --follow`), skipping schema dump/restore, COPY, and index creation entirely. Use this when you know the data copy is complete and only CDC streaming needs to restart. Logs are written to `resume-cdc-TIMESTAMP.log` in the migration directory.

To start completely over, wipe the target and clean up replication:

```bash
~/target-clean.sh
~/drop-replication-slots.sh
~/start-migration-screen.sh
```

## Filter Configuration

Every migration needs a `~/filters.ini` file to exclude objects that should not be copied. Use the filter to exclude source-specific schemas, tables, and extensions that are not needed on the target — particularly extensions not [supported by PlanetScale](https://planetscale.com/docs/postgres/extensions). The file uses pgcopydb's [filter syntax](https://github.com/planetscale/pgcopydb/blob/main/docs/ref/pgcopydb_filter.rst):

```ini
[exclude-schema]
schema_to_skip

[exclude-table]
public.table_to_skip

[exclude-extension]
extension_to_skip

[exclude-event-trigger]
trigger_to_skip
```

**Available sections:** `[exclude-schema]`, `[exclude-table]`, `[exclude-extension]`, `[exclude-event-trigger]`, `[include-only-schema]`, `[include-only-table]`. The `include-only` sections are mutually exclusive with the `exclude` sections.

**Important:** No comments are allowed inside sections — pgcopydb parses `#` lines as object names. Place all comments before the first section.

### Common Exclusions by Source

**Amazon RDS:**

```ini
[exclude-extension]
rds_tools
pg_repack
```

**Supabase:**

```ini
[exclude-schema]
auth
supabase_functions
storage
cron
realtime
supabase_migrations
net
_supabase
graphql
graphql_public

[exclude-extension]
pg_net
pg_graphql
pg_repack
http
pg_stat_monitor
pgstattuple

[exclude-event-trigger]
supabase_functions.hooks
```

**Google AlloyDB:**

```ini
[exclude-schema]
ai
google_ml
helpobj
perfsnap
pgsnap

[exclude-extension]
g_stats
google_columnar_engine
google_db_advisor
google_ml_integration
```

## Script Configuration

The migration scripts have tunable parameters at the top of each file:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `TABLE_JOBS` | 16 | Parallel COPY workers |
| `INDEX_JOBS` | 12 | Parallel index creation workers |
| `--split-tables-larger-than` | 50GB | Threshold for splitting large tables into parts |
| `--split-max-parts` | Same as TABLE_JOBS | Maximum number of parts per split table |

Adjust these based on your instance size and database characteristics. More jobs require more CPU cores and memory. A good baseline for `TABLE_JOBS` is fewer than the vCPU count of whichever is smaller — the SOURCE or TARGET. `INDEX_JOBS` should be fewer than the vCPUs on the TARGET. Exceeding these numbers can overwhelm the SOURCE during the COPY phase or the TARGET during index rebuilding. See [Cluster configuration parameters](https://planetscale.com/docs/postgres/cluster-configuration/parameters) for understanding target-side capacity.

## Troubleshooting

The migration log at `~/migration_*/migration.log` is the most valuable troubleshooting resource. It contains the full pgcopydb output including connection info, step-by-step progress with timestamps, table split decisions, extension filtering results, per-table COPY statistics, and full error details.

Every completed migration ends with a summary table showing wall clock and cumulative duration for each phase, total data transferred, and concurrency:

```
                                               Step   Connection    Duration    Transfer   Concurrency
 --------------------------------------------------   ----------  ----------  ----------  ------------
   Catalog Queries (table ordering, filtering, etc)       source       1s993                         1
                                        Dump Schema       source       224ms                         1
                                     Prepare Schema       target       755ms                         1
      COPY, INDEX, CONSTRAINTS, VACUUM (wall clock)         both      53m52s                        44
                                  COPY (cumulative)         both       1h15m      435 GB            16
                          CREATE INDEX (cumulative)       target       1h27m                        12
                           CONSTRAINTS (cumulative)       target       830ms                        12
                                VACUUM (cumulative)       target      12m39s                        16
                                    Reset Sequences         both        62ms                         1
                                    Finalize Schema         both         48s                        12
 --------------------------------------------------   ----------  ----------  ----------  ------------
                          Total Wall Clock Duration         both      54m42s                        60
```

**Useful searches in the log:**

- `grep ERROR migration.log` — find failures
- `grep "errors ignored on restore" migration.log` — pg_restore error count
- `grep -i split migration.log` — table partitioning decisions
- `grep s_depend migration.log` — extension filtering verification
- Check the last line for `Exit code: 0` (success) or non-zero (failure)

If `resume-migration.sh` was used, check `resume-*.log` files in the migration directory as well.

### SQLite Catalogs

pgcopydb tracks all migration state in SQLite databases inside the migration directory. Several of the monitoring scripts (`check-migration-status.sh`, `check-cdc-status.sh`, `stop-cdc.sh`) read directly from these catalogs.

- **`schema/source.db`** — Primary tracking database with per-table timing, bytes transferred, index/constraint progress, and CDC sentinel state (`replay_lsn`, `write_lsn`, `endpos`).
- **`schema/filter.db`** — Extension filtering state. The `s_depend` table must have rows after STEP 1 or extension-owned objects won't be filtered.

```bash
# Which tables are still copying?
sqlite3 ~/migration_*/schema/source.db \
  "SELECT nspname, relname, bytes FROM summary
   WHERE tableoid IS NOT NULL AND done_time_epoch IS NULL;"

# Largest tables and how long they took
sqlite3 ~/migration_*/schema/source.db \
  "SELECT nspname, relname, bytes, (done_time_epoch - start_time_epoch) as secs
   FROM summary WHERE tableoid IS NOT NULL AND done_time_epoch IS NOT NULL
   ORDER BY bytes DESC LIMIT 20;"

# CDC sentinel state (apply position, streaming position, endpos)
sqlite3 ~/migration_*/schema/source.db "SELECT * FROM sentinel;"

# Verify extension filtering worked
sqlite3 ~/migration_*/schema/filter.db "SELECT COUNT(*) FROM s_depend;"
```

## Script Reference

| Script | Phase | Description |
|--------|-------|-------------|
| `compare-pg-params.sh` | Prepare | Compare PostgreSQL parameters between source and target |
| `preflight-check.sh` | Prepare | Validate migration prerequisites (connectivity, WAL level, permissions, slots) |
| `fix-replica-identity.sh` | Prepare | Set REPLICA IDENTITY FULL on tables without primary keys |
| `filters.ini` | Prepare | pgcopydb filter configuration |
| `run-migration.sh` | Migrate | Start a pgcopydb clone --follow migration |
| `start-migration-screen.sh` | Migrate | Run the migration in a screen session |
| `check-migration-status.sh` | Monitor | Migration progress dashboard |
| `check-cdc-status.sh` | Monitor | CDC replication progress and health |
| `resume-migration.sh` | Recovery | Resume an interrupted migration (full clone + CDC) |
| `resume-cdc.sh` | Recovery | Resume only the CDC phase (skips clone) |
| `target-clean.sh` | Recovery | Wipe target database for re-migration (prompts for confirmation) |
| `drop-replication-slots.sh` | Cleanup | Remove replication slots and origins |
| `stop-cdc.sh` | Cutover | Set CDC endpoint via SQLite to initiate cutover |
| `verify-migration.sh` | Cutover | Verify schema and data consistency between source and target |

## Critical Warnings

- **Do not use `pgcopydb --restart`** — it wipes the CDC directory and SQLite catalogs without cleaning the target database or correcting previous failures. To start over, use `~/target-clean.sh` + `~/drop-replication-slots.sh` + `~/start-migration-screen.sh` instead.
- **Always clean up replication slots** when done — unconsumed slots cause unbounded WAL growth on the source.
- **Verify extension filtering after STEP 1** — if `s_depend` count is 0, extension-owned objects won't be excluded.
