# AGENTS.md

This file provides guidance to AI coding assistants (Claude Code, Cursor, Copilot, etc.) when helping with pgcopydb migrations using these scripts.

## Overview

These scripts run on a **migration instance** (EC2 or GCP Compute) that sits between the source PostgreSQL database and the [PlanetScale for Postgres](https://planetscale.com/docs/postgres/) target. The instance has pgcopydb installed and network access to both databases.

All scripts read connection strings from `~/.env`:

```bash
export PGCOPYDB_SOURCE_PGURI='postgresql://user:pass@source-host:5432/dbname'
export PGCOPYDB_TARGET_PGURI='postgresql://user:pass@target-host:5432/dbname'
```

## Script Reference

Scripts are organized by migration phase: preparation, execution, monitoring, recovery, and cutover.

---

### Pre-Migration

#### `compare-pg-params.sh`

Compares performance-relevant PostgreSQL parameters between source and target databases. Reports differences across 8 categories (resource usage, query tuning, WAL, connections, replication, autovacuum, statistics, memory) and flags which parameters require a restart vs reload to change.

```bash
~/compare-pg-params.sh
```

**When to use:** Before migration, to identify parameter differences that could cause performance regressions on the target. Share the output with PlanetScale to tune the target cluster. See [Cluster configuration parameters](https://planetscale.com/docs/postgres/cluster-configuration/parameters) for the full list of tunable settings.

**Requires:** `PGCOPYDB_SOURCE_PGURI`, `PGCOPYDB_TARGET_PGURI`

---

#### `verify-migration.sh`

Verifies that all data was copied correctly from source to target after a migration. Runs 11 checks covering schema, row counts, sequences, and data spot-checks — without full table scans. Safe for multi-TB databases; typically completes in under 2 minutes.

```bash
~/verify-migration.sh
~/verify-migration.sh --row-count-tolerance 1 --exact-count-tables 20
```

**Checks performed:**
- **Schema:** tables, columns (type/nullable/default), indexes, constraints (PK/FK/UNIQUE/CHECK), views, functions/procedures
- **Row counts:** fast estimates via `pg_class.reltuples` (no table scan), with configurable % tolerance
- **Sequences:** presence and `last_value` comparison
- **Data spot-check:** `MIN`/`MAX` on PK columns of the largest tables (index seeks only — no scan)
- **Exact row counts:** random sample of up to 10 tables ≤ 10 GB with real `COUNT(*)` and per-table timeout
- **Extensions:** presence and version match

**Options:**

| Flag | Default | Description |
|------|---------|-------------|
| `--row-count-tolerance <pct>` | 5 | Allowed % difference for `pg_class` row estimates |
| `--spot-check-tables <n>` | 20 | Number of tables for MIN/MAX spot-check |
| `--no-spot-check` | — | Skip MIN/MAX spot-check entirely |
| `--schemas <s1,s2,...>` | all | Restrict checks to specific schemas |
| `--exact-count-tables <n>` | 10 | Tables to exact-count (0 = skip) |
| `--exact-count-max-gb <n>` | 10 | Max table size in GB for exact count |
| `--exact-count-timeout <s>` | 120 | Per-table `COUNT(*)` timeout in seconds |

**When to use:** After `pgcopydb` finishes the initial COPY phase and before enabling CDC or cutting over. Run it multiple times — exact-count tables are chosen randomly, so repeated runs cover more tables.

**Interpreting row count mismatches:** `pg_class.reltuples` estimates are only refreshed by `ANALYZE`. Run `ANALYZE` on both DBs before running this script for the most accurate estimates. If target shows _more_ rows than source for some tables, the stats are stale — not a data problem.

**Exit codes:** `0` = all checks passed, `1` = warnings only, `2` = one or more failures.

**Requires:** `PGCOPYDB_SOURCE_PGURI`, `PGCOPYDB_TARGET_PGURI`

**Read-only** — makes no modifications to either database.

---

#### `preflight-check.sh`

Validates all migration prerequisites before starting `pgcopydb clone --follow`. Checks source, target, and migration instance, reporting PASS/WARN/FAIL for each item.

```bash
~/preflight-check.sh
```

**Checks performed:**
- **Source:** connectivity, `wal_level = logical`, replication permission (REPLICATION, SUPERUSER, or rds_replication), available replication slots, available WAL senders, leftover pgcopydb slot, FOR ALL TABLES publications, `wal_sender_timeout`, prepared transactions
- **Target:** connectivity, replication permission, leftover pgcopydb schema
- **Instance:** `~/filters.ini` exists, pgcopydb binary on PATH

**When to use:** Before every migration attempt. Run after setting up `~/.env` and `~/filters.ini` but before `~/start-migration-screen.sh`. Fix all FAILs before proceeding. Review WARNs — especially `wal_sender_timeout` (should be `0` for large migrations) and leftover state from previous attempts.

**Requires:** `PGCOPYDB_SOURCE_PGURI`, `PGCOPYDB_TARGET_PGURI`

**Exit code:** 0 if no FAILs, 1 if any FAILs.

**Read-only** — makes no modifications to either database.

---

#### `fix-replica-identity.sh`

Finds tables on the source that have default replica identity and no primary key or unique index, then generates `ALTER TABLE ... REPLICA IDENTITY FULL` statements. Previews the statements and prompts before applying.

```bash
~/fix-replica-identity.sh
```

**When to use:** Before starting a migration with `--follow` (CDC). Tables without a primary key and with default replica identity cannot be replicated via logical decoding. This script sets them to FULL so that CDC can track changes by comparing entire rows.

**Requires:** `PGCOPYDB_SOURCE_PGURI`

**Caution:** Runs ALTER TABLE on the **source** database. REPLICA IDENTITY FULL increases WAL volume for UPDATE/DELETE on affected tables. Review the list before confirming.

---

#### `filters.ini`

pgcopydb filter configuration file. Controls which schemas, tables, extensions, and event triggers are excluded from the migration.

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

**Important rules:**
- No comments allowed inside sections (pgcopydb parses `#` lines as object names)
- All comments must go before the first section
- `[exclude-extension]` uses `pg_depend` to find and exclude all objects owned by the listed extensions, including views and functions in `public`. See [supported extensions](https://planetscale.com/docs/postgres/extensions) for what PlanetScale supports
- After pgcopydb completes STEP 1 (catalog), verify extension filtering worked: `sqlite3 $DIR/schema/filter.db "SELECT COUNT(*) FROM s_depend;"` must be > 0

**When to customize:** Every migration needs a filters.ini. Common exclusions:
- **RDS:** `rds_tools`, `pg_repack` extensions
- **Supabase:** `auth`, `storage`, `supabase_functions`, `cron`, `realtime`, `supabase_migrations`, `net`, `_supabase`, `graphql`, `graphql_public` schemas; `pg_net`, `pg_graphql`, `pg_repack`, `http`, `pg_stat_monitor`, `pgstattuple` extensions; `supabase_functions.hooks` event trigger
- **AlloyDB:** `ai`, `google_ml`, `helpobj`, `perfsnap`, `pgsnap` schemas; `g_stats`, `google_columnar_engine`, `google_db_advisor`, `google_ml_integration` extensions

---

### Running a Migration

#### `run-migration.sh`

Starts a full `pgcopydb clone --follow` migration. Creates a new timestamped directory (`~/migration_YYYYMMDD-HHMMSS/`), enables core dumps, and logs all output.

```bash
~/run-migration.sh
```

**Default configuration (edit the script to adjust):**
- `TABLE_JOBS=16` — parallel COPY workers
- `INDEX_JOBS=12` — parallel index creation workers
- `--split-tables-larger-than 50GB` — splits large tables into parts
- `--split-max-parts` matches TABLE_JOBS
- `--plugin wal2json` — logical decoding plugin for CDC
- `--filter ~/filters.ini`

**When to use:** Starting a fresh migration. For a COPY-only test (no CDC), remove the `--follow` and `--plugin` flags.

**Requires:** `PGCOPYDB_SOURCE_PGURI`, `PGCOPYDB_TARGET_PGURI`, `~/filters.ini`

---

#### `start-migration-screen.sh`

Wrapper that runs `run-migration.sh` inside a detached `screen` session named "migration". Kills any existing migration screen first.

```bash
~/start-migration-screen.sh
```

**When to use:** Always use this instead of running `run-migration.sh` directly. Screen prevents the migration from dying if your SSH session disconnects.

**Useful commands after starting:**
- `screen -r migration` — attach to watch live output
- `Ctrl-A D` — detach from screen (migration keeps running)
- `~/check-migration-status.sh` — check progress without attaching

---

### Monitoring

#### `check-migration-status.sh`

Displays a full migration progress dashboard: phase completion status, table/index/constraint copy progress, CDC streaming, error counts, runtime, and active database operations on the target.

```bash
~/check-migration-status.sh
```

**Output includes:**
- Phase 1-10 status (catalog, dump, restore, copy, indexes, constraints, vacuum, sequences, post-data)
- Copy task progress with split table tracking
- Data transferred in GB
- pg_restore error counts (within tolerance vs exceeds)
- Active queries on the target (COPY, CREATE INDEX, VACUUM, etc.)

**Requires:** `PGCOPYDB_TARGET_PGURI` (for active operations query). Reads from the most recent `~/migration_*` directory.

---

#### `check-cdc-status.sh`

Displays CDC-specific replication progress: apply and streaming LSN positions, backlog gap, apply rate, ETA to catch-up, and source replication slot health.

```bash
~/check-cdc-status.sh
```

**Output includes:**
- Apply LSN and streaming LSN (from sentinel SQLite DB)
- Apply backlog in GB/MB
- Apply rate (GB/hr) and estimated time to catch up
- Source replication slot flush lag, restart lag, and WAL status
- Process count (confirms pgcopydb is still running)

**When to use:** After the initial COPY completes and CDC is actively streaming. Use this to determine when the migration is caught up and ready for cutover.

**Key indicator:** "CDC IS CAUGHT UP" (gap < 100 MB) means you can proceed with cutover.

**Requires:** `PGCOPYDB_SOURCE_PGURI`, `PGCOPYDB_TARGET_PGURI`

---

### Recovery

#### `resume-migration.sh`

Resumes a previously interrupted `pgcopydb clone --follow` migration. Backs up the SQLite catalog before resuming.

```bash
~/resume-migration.sh                                                    # uses most recent migration dir
MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/resume-migration.sh          # specify explicitly
```

**Important:** The script passes `--split-tables-larger-than` to match `run-migration.sh`. pgcopydb requires catalog consistency — if the original run used split tables, the resume must pass the same value.

**When to use:** After pgcopydb crashes, the instance reboots, or the migration is interrupted. To start completely over instead, run `~/target-clean.sh` + `~/drop-replication-slots.sh` first, then `~/start-migration-screen.sh`.

**Requires:** `PGCOPYDB_SOURCE_PGURI`, `PGCOPYDB_TARGET_PGURI`, existing migration directory

---

#### `resume-cdc.sh`

Resumes only the CDC phase of a previously interrupted migration using `pgcopydb follow`. Does not re-attempt the clone (schema dump/restore, COPY, index creation).

```bash
~/resume-cdc.sh                                                          # uses most recent migration dir
MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/resume-cdc.sh                # specify explicitly
```

**When to use:** After the initial COPY completed successfully but CDC was interrupted (crash, reboot, connection drop). If you are unsure whether COPY finished, use `resume-migration.sh` instead — it will resume from wherever pgcopydb left off. Logs are written to `resume-cdc-TIMESTAMP.log` in the migration directory.

**Requires:** `PGCOPYDB_SOURCE_PGURI`, `PGCOPYDB_TARGET_PGURI`, existing migration directory with completed COPY

---

#### `target-clean.sh`

Wipes all user objects from the target database for a fresh re-migration. Shows a summary of what will be dropped and prompts for confirmation.

```bash
~/target-clean.sh
```

**What it drops:** All non-default schemas (CASCADE), materialized views, publications, event triggers, standalone custom types. Recreates the `public` schema from scratch. Verifies no stale custom types remain.

**What it preserves:** `pg_catalog`, `information_schema`, `pscale_extensions` (see [Managing Roles](https://planetscale.com/docs/postgres/connecting/roles)), extension-owned objects.

**When to use:** Before retrying a migration from scratch. Always run this before `run-migration.sh` on a second attempt.

**Caution:** This is destructive — it wipes everything on the target. Does NOT use `DROP OWNED BY ... CASCADE` (that approach leaves stale composite types that cause COPY failures).

**Requires:** `PGCOPYDB_TARGET_PGURI`

---

#### `drop-replication-slots.sh`

Cleans up pgcopydb replication artifacts on both source and target databases.

```bash
~/drop-replication-slots.sh              # uses default slot name "pgcopydb"
~/drop-replication-slots.sh my_slot      # custom slot name
```

**What it cleans:**
- **Source:** Drops the logical replication slot (terminates active consumer if needed)
- **Target:** Drops the replication origin and the `pgcopydb` sentinel schema

**When to use:** After a migration completes or is abandoned. Replication slots that are not consumed will cause WAL to accumulate on the source until the disk fills up. Always clean up slots when done.

**Requires:** `PGCOPYDB_SOURCE_PGURI`, `PGCOPYDB_TARGET_PGURI`

---

### Cutover

#### `stop-cdc.sh`

Sets the CDC endpoint LSN so pgcopydb stops streaming after reaching a specific position. This is how you initiate cutover. The script fetches the current WAL LSN from the source automatically, displays it, and prompts for confirmation before writing it to the sentinel.

```bash
~/stop-cdc.sh
MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/stop-cdc.sh  # explicit dir
```

**Cutover procedure:**
1. Stop writes to the source database (maintenance mode, read-only, etc.)
2. Run `stop-cdc.sh` — it fetches the current WAL LSN, shows it, and asks you to confirm
3. Wait for `check-cdc-status.sh` to show the apply LSN has reached the endpoint
4. pgcopydb exits cleanly
5. Verify data on the target
6. Switch application to the target
7. Run `drop-replication-slots.sh` to clean up

**Requires:** `PGCOPYDB_SOURCE_PGURI`, `PGCOPYDB_TARGET_PGURI`

---

## Troubleshooting with the Migration Log

The migration log (`~/migration_*/migration.log`) is the single most valuable troubleshooting artifact. It contains the full pgcopydb output including:

- **Connection strings** (sanitized) and pgcopydb version at the top
- **STEP-by-step progress** with timestamps for every phase
- **Table split decisions** — which tables were split, how many parts, and why (size, CTID vs integer partitioning)
- **Extension filtering results** — how many extensions matched, how many `pg_depend` entries were found
- **Per-table COPY details** — OID, schema, table name, parts, duration, bytes transferred, index count, and index creation time
- **Error details** — full stack traces, pg_restore errors with the failing SQL, connection failures
- **End-of-run summary table** — wall clock and cumulative duration for each phase (COPY, INDEX, CONSTRAINTS, VACUUM), total data transferred, and concurrency used

Example end-of-run summary:
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

**Key troubleshooting patterns:**
- Search for `ERROR` to find failures
- Search for `errors ignored on restore:` to see pg_restore error count
- Search for `Splitting` or `split` to see table partitioning decisions
- Search for `s_depend` or `pg_depend` to verify extension filtering
- Check the exit code at the end: `Exit code: 0` means success
- If resume logs exist (`resume-*.log`), check those too — they contain output from `resume-migration.sh` runs

When asking for help with a failed migration, share the full log or at minimum the last 100 lines and any ERROR lines.

### pgcopydb SQLite Catalogs

pgcopydb tracks all migration state in SQLite databases inside the migration directory. Several of the monitoring scripts read directly from these catalogs, and they are invaluable for troubleshooting:

- **`schema/source.db`** — The primary tracking database. Contains tables for every object being migrated:
  - `s_table` — all tables with OIDs, sizes, and row estimates
  - `s_table_part` — split table parts (when using `--split-tables-larger-than`)
  - `s_index` — all indexes
  - `s_constraint` — all constraints
  - `summary` — per-object timing: start/done epochs, bytes transferred (used by `check-migration-status.sh`)
  - `vacuum_summary` — vacuum completion tracking
  - `sentinel` — CDC state: `replay_lsn`, `write_lsn`, `endpos` (used by `check-cdc-status.sh` and `stop-cdc.sh`)

- **`schema/filter.db`** — Extension filtering state:
  - `s_depend` — objects matched via `pg_depend` for `[exclude-extension]` filtering. **Must have rows > 0** after STEP 1 or extension-owned objects in `public` won't be filtered.

**Useful queries:**
```bash
# Check which tables are still copying
sqlite3 ~/migration_*/schema/source.db \
  "SELECT s.nspname, s.relname, s.bytes, s.start_time_epoch, s.done_time_epoch
   FROM summary s WHERE s.tableoid IS NOT NULL AND s.done_time_epoch IS NULL;"

# Check the largest tables and their copy times
sqlite3 ~/migration_*/schema/source.db \
  "SELECT nspname, relname, bytes, (done_time_epoch - start_time_epoch) as secs
   FROM summary WHERE tableoid IS NOT NULL AND done_time_epoch IS NOT NULL
   ORDER BY bytes DESC LIMIT 20;"

# Check CDC sentinel state
sqlite3 ~/migration_*/schema/source.db \
  "SELECT * FROM sentinel;"

# Verify extension filtering
sqlite3 ~/migration_*/schema/filter.db \
  "SELECT COUNT(*) FROM s_depend;"
```

---

## Typical Migration Workflow

```
1. PREPARE
   - Set up ~/.env with connection strings
   - Customize ~/filters.ini for your source
   - Run ~/compare-pg-params.sh to review parameter differences
   - Run ~/preflight-check.sh to validate prerequisites (fix FAILs before proceeding)
   - Run ~/fix-replica-identity.sh if using CDC (--follow)

2. MIGRATE
   - Run ~/start-migration-screen.sh to begin
   - Monitor with ~/check-migration-status.sh (initial copy phase)
   - Monitor with ~/check-cdc-status.sh (CDC catch-up phase)

3. CUTOVER (when CDC is caught up)
   - Stop writes to source
   - Run ~/stop-cdc.sh — to set the endpoint
   - Wait for pgcopydb to finish applying and exit
   - Verify data on target
   - Switch application to target

4. CLEANUP
   - Run ~/drop-replication-slots.sh to remove replication artifacts

IF SOMETHING GOES WRONG:
   - Run ~/resume-migration.sh to resume after a crash (full clone + CDC)
   - Run ~/resume-cdc.sh to resume only CDC (when COPY already completed)
   - Run ~/target-clean.sh + ~/drop-replication-slots.sh to start over
```

## Configuration

All scripts use variables at the top that can be adjusted per migration. See [Cluster configuration parameters](https://planetscale.com/docs/postgres/cluster-configuration/parameters) for understanding target-side capacity when tuning these values:

| Variable | Default | Used in |
|----------|---------|---------|
| `TABLE_JOBS` | 16 | run-migration.sh, resume-migration.sh |
| `INDEX_JOBS` | 12 | run-migration.sh, resume-migration.sh |
| `FILTER_FILE` | ~/filters.ini | run-migration.sh, resume-migration.sh, resume-cdc.sh |
| `--split-tables-larger-than` | 50GB | run-migration.sh, resume-migration.sh |

## Critical Warnings

- **Do not use `pgcopydb --restart`** — it wipes the CDC directory and SQLite catalogs without cleaning the target database or correcting previous failures. To start over, use `~/target-clean.sh` + `~/drop-replication-slots.sh` + `~/start-migration-screen.sh` instead.
- **Always clean up replication slots** after a migration — unconsumed slots cause WAL accumulation on the source.
- **Verify extension filtering after STEP 1** — check `SELECT COUNT(*) FROM s_depend;` in `filter.db`. If it's 0, extension-owned objects in `public` won't be filtered.
- **pg_restore error tolerance** — pgcopydb allows up to 10 restore errors by default. If your migration has more, you may need a custom build with a higher `MAX_TOLERATED_RESTORE_ERRORS`.
