#!/bin/bash
#
# Usage: ~/check-copy-stall.sh [--no-sample] [--sample-secs N]
#
# Diagnoses a stalled or slow pgcopydb COPY by inspecting live session, lock,
# and wait state on the TARGET (PlanetScale) database. Answers the two questions
# that matter when a migration looks stuck:
#
#   1. Is anything actually blocked on a lock (and who holds it)?
#   2. Where is time being spent — waiting on the client/source feed, on disk
#      IO, on WAL, or on a lock — and is data still landing at all?
#
# Read-only: connects with default_transaction_read_only=on and a statement
# timeout. Makes no modifications to the target. Run it from the migration
# instance, the same place the migration runs.
#
# Requires: PGCOPYDB_TARGET_PGURI (from ~/.env)
#
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Options ---
SAMPLE=true
SAMPLE_SECS=5
while [ $# -gt 0 ]; do
    case "$1" in
        --no-sample)    SAMPLE=false; shift ;;
        --sample-secs)  SAMPLE_SECS="${2:-5}"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set -eo/p' "$0" | sed 's/^# \{0,1\}//; /^set -eo/d'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Load environment ---
set +u
set -a
# shellcheck disable=SC1090
source ~/.env
set +a
set -u

if [ -z "${PGCOPYDB_TARGET_PGURI:-}" ]; then
    echo -e "${RED}✗ PGCOPYDB_TARGET_PGURI is not set (check ~/.env)${NC}"
    exit 1
fi

# Read-only, time-bounded psql. default_transaction_read_only guarantees the
# session cannot write even if a query were changed to do so; statement_timeout
# and lock_timeout keep a diagnostic from ever hanging on a busy target.
PGOPTS='-c default_transaction_read_only=on -c statement_timeout=30000 -c lock_timeout=5000'
run_table()  { PGOPTIONS="$PGOPTS" psql "$PGCOPYDB_TARGET_PGURI" -X -q -P pager=off -P footer=off -c "$1" || true; }
run_scalar() { PGOPTIONS="$PGOPTS" psql "$PGCOPYDB_TARGET_PGURI" -X -q -t -A -c "$1" 2>/dev/null || echo ""; }

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  PlanetScale Migration — COPY Stall Diagnostics (target side)   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# --- Connectivity ---
TARGET_DB=$(run_scalar "SELECT current_database()")
if [ -z "$TARGET_DB" ]; then
    echo -e "${RED}✗ Could not connect to the target database via PGCOPYDB_TARGET_PGURI${NC}"
    echo "  Check the URI in ~/.env and network access from this instance."
    exit 1
fi
echo "Target database: $TARGET_DB"
echo "Generated:       $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

# ── 1. Is anything lock-blocked? (the headline question) ──
echo "────────────────────────────────────────────────────────────────"
echo "1. BLOCKING TREE  (who is waiting on a lock, and who holds it)"
echo "────────────────────────────────────────────────────────────────"
BLOCKED_COUNT=$(run_scalar "SELECT count(*) FROM pg_stat_activity b WHERE b.pid <> pg_backend_pid() AND cardinality(pg_blocking_pids(b.pid)) > 0")
BLOCKED_COUNT=$(echo "${BLOCKED_COUNT:-0}" | tr -d '[:space:]')
if [ "${BLOCKED_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "${RED}✗ $BLOCKED_COUNT session(s) blocked on a lock:${NC}"
    run_table "
        SELECT blocked.pid AS blocked_pid,
               coalesce(blocked.wait_event_type||':'||blocked.wait_event,'-') AS waiting_on,
               blocking.pid AS blocking_pid,
               blocking.state AS blocker_state,
               (now()-blocking.xact_start)::interval(0) AS blocker_xact_age,
               left(regexp_replace(blocked.query, E'[\\n\\r]+',' ','g'),45) AS blocked_query,
               left(regexp_replace(blocking.query,E'[\\n\\r]+',' ','g'),45) AS blocker_query
        FROM pg_stat_activity blocked
        JOIN pg_stat_activity blocking ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
        WHERE blocked.pid <> pg_backend_pid()
        ORDER BY blocked.pid;"
    echo ""
    echo "  → A COPY here is genuinely lock-blocked. Look at blocking_pid:"
    echo "    if it is 'idle in transaction', a stuck client transaction is the cause."
else
    echo -e "${GREEN}✓ Nothing is lock-blocked.${NC} No session is waiting on a lock held by another."
fi
echo ""

# ── 2. Locks that haven't been granted yet ──
echo "────────────────────────────────────────────────────────────────"
echo "2. UNGRANTED LOCKS  (sessions waiting to acquire a lock)"
echo "────────────────────────────────────────────────────────────────"
UNGRANTED=$(run_scalar "SELECT count(*) FROM pg_locks WHERE NOT granted")
UNGRANTED=$(echo "${UNGRANTED:-0}" | tr -d '[:space:]')
if [ "${UNGRANTED:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "${YELLOW}$UNGRANTED ungranted lock request(s):${NC}"
    run_table "
        SELECT a.pid,
               coalesce(a.wait_event_type||':'||a.wait_event,'-') AS wait,
               l.locktype, l.mode,
               coalesce(l.relation::regclass::text,'-') AS relation,
               pg_blocking_pids(a.pid) AS blocked_by,
               left(regexp_replace(a.query,E'[\\n\\r]+',' ','g'),40) AS query
        FROM pg_stat_activity a
        JOIN pg_locks l ON l.pid = a.pid AND NOT l.granted
        ORDER BY a.pid;"
else
    echo -e "${GREEN}✓ No ungranted locks.${NC} Nothing is queued waiting to acquire a lock."
fi
echo ""

# ── 3. Where is everyone spending time? ──
echo "────────────────────────────────────────────────────────────────"
echo "3. WAIT-EVENT SUMMARY  (what the backends are doing right now)"
echo "────────────────────────────────────────────────────────────────"
run_table "
    SELECT backend_type,
           coalesce(state,'-') AS state,
           coalesce(wait_event_type,'(running)') AS wait_type,
           coalesce(wait_event,'-') AS wait_event,
           count(*) AS sessions
    FROM pg_stat_activity
    WHERE backend_type IS NOT NULL
    GROUP BY 1,2,3,4
    ORDER BY sessions DESC;"
echo ""
echo "  Reading it: Client/ClientRead on COPYs = waiting on the source feed"
echo "  (pgcopydb / source / network — NOT a target-side problem). IO/DataFileRead"
echo "  or IO/DataFileWrite = disk-bound. IO/WALWrite = WAL-bound. Lock/LWLock ="
echo "  contention — chase it in sections 1-2. IPC/SyncRep = waiting on a replica ack."
echo ""

# ── 4. Active COPY operations and their progress ──
echo "────────────────────────────────────────────────────────────────"
echo "4. ACTIVE COPY OPERATIONS  (oldest first = stall suspects)"
echo "────────────────────────────────────────────────────────────────"
COPY_COUNT=$(run_scalar "SELECT count(*) FROM pg_stat_progress_copy")
COPY_COUNT=$(echo "${COPY_COUNT:-0}" | tr -d '[:space:]')
if [ "${COPY_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    run_table "
        SELECT p.pid,
               p.relid::regclass AS target_table,
               pg_size_pretty(p.bytes_processed) AS copied,
               p.tuples_processed AS rows,
               coalesce(a.wait_event_type||':'||a.wait_event,'(running)') AS wait,
               (now()-a.query_start)::interval(0) AS copy_age
        FROM pg_stat_progress_copy p
        JOIN pg_stat_activity a USING (pid)
        ORDER BY a.query_start;"
    echo ""
    echo "  bytes_total is 0 for COPY FROM STDIN (streamed), so judge progress by"
    echo "  rows/copied changing between runs — not by a single snapshot. pgcopydb"
    echo "  cycles parts through its worker pool, so pids come and go normally."
else
    echo "  No COPY operations currently running on the target."
fi
echo ""

# ── 5. Vacuums competing with the load ──
echo "────────────────────────────────────────────────────────────────"
echo "5. RUNNING VACUUMS  (autovacuum contends for IO/WAL during a load)"
echo "────────────────────────────────────────────────────────────────"
VAC_COUNT=$(run_scalar "SELECT count(*) FROM pg_stat_progress_vacuum")
VAC_COUNT=$(echo "${VAC_COUNT:-0}" | tr -d '[:space:]')
if [ "${VAC_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    run_table "
        SELECT a.pid,
               p.relid::regclass AS table,
               p.phase,
               coalesce(a.wait_event,'(running)') AS wait,
               CASE WHEN p.heap_blks_total > 0
                    THEN round(100.0*p.heap_blks_scanned/p.heap_blks_total,1) END AS pct_scanned,
               (now()-a.xact_start)::interval(0) AS age
        FROM pg_stat_progress_vacuum p
        JOIN pg_stat_activity a USING (pid)
        ORDER BY (now()-a.xact_start) DESC;"
    echo ""
    echo "  Autovacuum does NOT lock-block a COPY (lock modes don't conflict), but a"
    echo "  full-table vacuum on a table being loaded steals IO/WAL bandwidth and can"
    echo "  throttle throughput. To reduce it during the load, on the target:"
    echo "    ALTER TABLE <table> SET (autovacuum_enabled = false);   -- re-enable + ANALYZE after"
    echo "  (Disabling stops future cycles; terminate a running worker for immediate effect.)"
else
    echo -e "${GREEN}✓ No autovacuum running right now.${NC}"
fi
echo ""

# ── 6. Idle-in-transaction sessions (pin xmin; pgcopydb workers parked) ──
echo "────────────────────────────────────────────────────────────────"
echo "6. IDLE-IN-TRANSACTION  (parked worker conns; pin the vacuum horizon)"
echo "────────────────────────────────────────────────────────────────"
IIT_COUNT=$(run_scalar "SELECT count(*) FROM pg_stat_activity WHERE state='idle in transaction'")
IIT_COUNT=$(echo "${IIT_COUNT:-0}" | tr -d '[:space:]')
echo "  $IIT_COUNT session(s) idle in transaction."
if [ "${IIT_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    run_table "
        SELECT pid,
               (now()-xact_start)::interval(0) AS idle_in_xact_for,
               left(regexp_replace(query,E'[\\n\\r]+',' ','g'),40) AS last_query
        FROM pg_stat_activity
        WHERE state='idle in transaction'
        ORDER BY xact_start
        LIMIT 20;"
    echo ""
    echo "  A handful is normal (pgcopydb workers between parts). Many long-lived ones"
    echo "  pin the global xmin horizon, which forces autovacuum to re-scan large"
    echo "  tables repeatedly (heavy WAL) without being able to clean anything."
fi
echo ""

# ── 7. Optional: is data actually landing? (throughput sample) ──
if [ "$SAMPLE" = true ]; then
    echo "────────────────────────────────────────────────────────────────"
    echo "7. INGEST THROUGHPUT  (sampled over ${SAMPLE_SECS}s)"
    echo "────────────────────────────────────────────────────────────────"
    S0=$(run_scalar "SELECT pg_current_wal_lsn() || '|' || pg_database_size(current_database())")
    sleep "$SAMPLE_SECS"
    S1=$(run_scalar "SELECT pg_current_wal_lsn() || '|' || pg_database_size(current_database())")
    L0="${S0%%|*}"; B0="${S0##*|}"
    L1="${S1%%|*}"; B1="${S1##*|}"
    if [ -n "$L0" ] && [ -n "$L1" ]; then
        run_table "
            SELECT pg_size_pretty(pg_wal_lsn_diff('$L1','$L0'))                       AS wal_written,
                   pg_size_pretty(GREATEST($B1-$B0,0))                                 AS db_growth,
                   pg_size_pretty((GREATEST($B1-$B0,0)/$SAMPLE_SECS))                  AS avg_ingest_per_s;"
        echo ""
        echo "  Non-zero WAL/growth means the database is actively ingesting even if a"
        echo "  particular COPY stream looks idle. Re-run to compare."
    else
        echo "  (could not sample WAL/size)"
    fi
    echo ""
fi

echo "════════════════════════════════════════════════════════════════"
echo "SUMMARY"
echo "════════════════════════════════════════════════════════════════"
if [ "${BLOCKED_COUNT:-0}" -gt 0 ] 2>/dev/null || [ "${UNGRANTED:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "${RED}A lock IS involved${NC} — see sections 1-2 for the blocking session."
else
    echo -e "${GREEN}Nothing is lock-blocked on the target.${NC} If a COPY looks stuck, it is"
    echo "almost certainly waiting on its source feed (ClientRead in section 3) or being"
    echo "throttled by autovacuum IO (section 5) — not blocked by the PlanetScale database."
    echo "Confirm overall progress with section 7 and ~/check-migration-status.sh."
fi
echo ""
