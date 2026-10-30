#!/bin/bash
#
# Usage: ~/check-source-speed.sh [--sample-secs N] [--wire-test] [--no-wire-test]
#
# Diagnoses a slow migration by measuring where the SOURCE database is spending
# its time. Use it when the copy is running but throughput looks low and the
# migration instance and target are both idle. Answers:
#
#   1. What are the COPY workers waiting on — source disk, the network, a lock,
#      or nothing (CPU)?
#   2. How fast is the source actually reading from disk, in IOPS and MB/s?
#   3. How much does the data expand on the wire (TOAST is compressed on disk,
#      COPY output is not), and what does that mean for the total transfer?
#   4. Is the network path healthy, and what can one connection carry?
#
# Read-only: connects with default_transaction_read_only=on and a statement
# timeout. Makes no modifications to the source. Run it from the migration
# instance, the same place the migration runs.
#
# --wire-test streams ~500MB of server-generated data to measure the network
# path with no disk involvement. It adds load to the source, so it is off by
# default. Nothing else in this script adds meaningful load.
#
# Requires: PGCOPYDB_SOURCE_PGURI (from ~/.env)
#
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Options ---
SAMPLE_SECS=30
WIRE_TEST=false
while [ $# -gt 0 ]; do
    case "$1" in
        --sample-secs)
            SAMPLE_SECS="${2:-30}"
            [ "$SAMPLE_SECS" -gt 0 ] 2>/dev/null || { echo "--sample-secs must be a positive integer" >&2; exit 1; }
            shift 2 ;;
        --wire-test)    WIRE_TEST=true; shift ;;
        --no-wire-test) WIRE_TEST=false; shift ;;
        -h|--help)
            sed -n '2,/^set -eo/p' "$0" | sed 's/^# \{0,1\}//; /^set -eo/d'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Load environment ---
if [ ! -f ~/.env ]; then
    echo "ERROR: ~/.env not found. Create it from the template:" >&2
    echo "  cp ~/env-template ~/.env && chmod 600 ~/.env" >&2
    exit 1
fi
set +u
set -a
# shellcheck disable=SC1090
source ~/.env
set +a
set -u

if [ -z "${PGCOPYDB_SOURCE_PGURI:-}" ]; then
    echo -e "${RED}✗ PGCOPYDB_SOURCE_PGURI is not set (check ~/.env)${NC}"
    exit 1
fi

# Read-only, time-bounded psql. This runs against the production
# source, so every session is barred from writing and cannot hang.
PGOPTS='-c default_transaction_read_only=on -c statement_timeout=30000 -c lock_timeout=5000'
run_table()  { PGOPTIONS="$PGOPTS" psql "$PGCOPYDB_SOURCE_PGURI" -X -q -P pager=off -P footer=off -c "$1" || true; }
run_scalar() { PGOPTIONS="$PGOPTS" psql "$PGCOPYDB_SOURCE_PGURI" -X -q -t -A -c "$1" 2>/dev/null || echo ""; }

# Print a rate in MB/s from a byte delta and a seconds value.
mbps() { awk -v b="$1" -v s="$2" 'BEGIN { if (s > 0) printf "%.1f", b / s / 1048576; else printf "0.0" }'; }
# Divide two numbers, guarding against a zero denominator.
ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.2f", a / b; else printf "0" }'; }

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  PlanetScale Migration — Source Speed Diagnostics (source side) ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# --- Connectivity ---
SOURCE_DB=$(run_scalar "SELECT current_database()")
if [ -z "$SOURCE_DB" ]; then
    echo -e "${RED}✗ Could not connect to the source database via PGCOPYDB_SOURCE_PGURI${NC}"
    echo "  Check the URI in ~/.env and network access from this instance."
    exit 1
fi
PGVER_NUM=$(run_scalar "SELECT current_setting('server_version_num')")
PGVER=$(run_scalar "SELECT current_setting('server_version')")
SOURCE_ROLE=$(run_scalar "SELECT current_user")
echo "Source database: $SOURCE_DB (PostgreSQL $PGVER)"
echo "Connected as:    $SOURCE_ROLE"
echo "Sample window:   ${SAMPLE_SECS}s"
echo "Generated:       $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

# ── 1. What are the COPY workers waiting on? (the headline question) ──
echo "────────────────────────────────────────────────────────────────"
echo "1. WORKER WAIT STATES  (where the source is spending its time)"
echo "────────────────────────────────────────────────────────────────"
WORKERS=$(run_scalar "SELECT count(*) FROM pg_stat_activity WHERE usename = current_user AND pid <> pg_backend_pid() AND backend_type = 'client backend'")
WORKERS=$(echo "${WORKERS:-0}" | tr -d '[:space:]')

if [ "${WORKERS:-0}" -eq 0 ] 2>/dev/null; then
    echo -e "${YELLOW}No sessions found for role \"$SOURCE_ROLE\" other than this one.${NC}"
    echo "  The copy may not be running, or pgcopydb connects as a different role."
    echo "  Check with ~/check-migration-status.sh."
else
    echo "Sessions for role \"$SOURCE_ROLE\": $WORKERS"
    echo ""
    run_table "SELECT coalesce(wait_event_type,'(running)') AS wait_type,
                      coalesce(wait_event,'(none)') AS wait_event,
                      count(*) AS sessions
                 FROM pg_stat_activity
                WHERE usename = current_user AND pid <> pg_backend_pid() AND backend_type = 'client backend'
                GROUP BY 1,2 ORDER BY 3 DESC"
fi

IO_WAITS=$(run_scalar "SELECT count(*) FROM pg_stat_activity WHERE usename = current_user AND pid <> pg_backend_pid() AND backend_type = 'client backend' AND wait_event_type = 'IO'")
CLIENT_WAITS=$(run_scalar "SELECT count(*) FROM pg_stat_activity WHERE usename = current_user AND pid <> pg_backend_pid() AND backend_type = 'client backend' AND wait_event = 'ClientWrite'")
LOCK_WAITS=$(run_scalar "SELECT count(*) FROM pg_stat_activity WHERE usename = current_user AND pid <> pg_backend_pid() AND backend_type = 'client backend' AND wait_event_type IN ('Lock','LWLock')")
IO_WAITS=$(echo "${IO_WAITS:-0}" | tr -d '[:space:]')
CLIENT_WAITS=$(echo "${CLIENT_WAITS:-0}" | tr -d '[:space:]')
LOCK_WAITS=$(echo "${LOCK_WAITS:-0}" | tr -d '[:space:]')

echo ""
echo "  IO/DataFileRead  = blocked on source storage (storage is the ceiling)"
echo "  Client/ClientWrite = source has data ready, waiting on the network or consumer"
echo "  Lock/LWLock      = contending with the application workload"
echo "  (running)        = source CPU bound"
echo ""

# ── 2. Live COPY throughput ──
echo "────────────────────────────────────────────────────────────────"
echo "2. COPY THROUGHPUT  (${SAMPLE_SECS}s sample)"
echo "────────────────────────────────────────────────────────────────"
COPY_TASKS=$(run_scalar "SELECT count(*) FROM pg_stat_progress_copy")
COPY_TASKS=$(echo "${COPY_TASKS:-0}" | tr -d '[:space:]')

BYTES_1=$(run_scalar "SELECT coalesce(sum(bytes_processed),0) FROM pg_stat_progress_copy")
IO_1=$(run_scalar "SELECT coalesce(sum(reads),0)||' '||coalesce(sum(writes),0)||' '||coalesce(sum(extends),0) FROM pg_stat_io" )
BLKS_1=$(run_scalar "SELECT blks_read FROM pg_stat_database WHERE datname = current_database()")
T_START=$(date +%s)

sleep "$SAMPLE_SECS"

BYTES_2=$(run_scalar "SELECT coalesce(sum(bytes_processed),0) FROM pg_stat_progress_copy")
IO_2=$(run_scalar "SELECT coalesce(sum(reads),0)||' '||coalesce(sum(writes),0)||' '||coalesce(sum(extends),0) FROM pg_stat_io")
BLKS_2=$(run_scalar "SELECT blks_read FROM pg_stat_database WHERE datname = current_database()")
T_END=$(date +%s)
ELAPSED=$(( T_END - T_START ))
[ "$ELAPSED" -gt 0 ] || ELAPSED=1

COPY_DELTA=$(( ${BYTES_2:-0} - ${BYTES_1:-0} ))
[ "$COPY_DELTA" -ge 0 ] || COPY_DELTA=0   # a part finishing resets its counter
COPY_MBPS=$(mbps "$COPY_DELTA" "$ELAPSED")

echo "Active COPY tasks:   ${COPY_TASKS:-0}"
echo "COPY output:         $(awk -v b="$COPY_DELTA" 'BEGIN{printf "%.2f", b/1073741824}') GB in ${ELAPSED}s"
echo -e "COPY throughput:     ${GREEN}${COPY_MBPS} MB/s${NC}"
echo ""
echo "  Note: bytes_processed resets when a part finishes, so this can read low"
echo "  if parts completed during the sample. Re-run to confirm."
echo ""

# ── 3. Storage read rate ──
echo "────────────────────────────────────────────────────────────────"
echo "3. SOURCE STORAGE IO  (same ${ELAPSED}s window)"
echo "────────────────────────────────────────────────────────────────"
PHYS_BYTES=0
if [ -n "$IO_1" ] && [ -n "$IO_2" ] && [ "${PGVER_NUM:-0}" -ge 160000 ] 2>/dev/null; then
    R1=$(echo "$IO_1" | awk '{print $1}'); W1=$(echo "$IO_1" | awk '{print $2}'); E1=$(echo "$IO_1" | awk '{print $3}')
    R2=$(echo "$IO_2" | awk '{print $1}'); W2=$(echo "$IO_2" | awk '{print $2}'); E2=$(echo "$IO_2" | awk '{print $3}')
    D_READ=$(( R2 - R1 )); D_WRITE=$(( W2 - W1 )); D_EXT=$(( E2 - E1 ))
    TOTAL_IOPS=$(awk -v r="$D_READ" -v w="$D_WRITE" -v e="$D_EXT" -v s="$ELAPSED" 'BEGIN{printf "%.0f", (r+w+e)/s}')
    READ_IOPS=$(awk -v r="$D_READ" -v s="$ELAPSED" 'BEGIN{printf "%.0f", r/s}')
    PHYS_BYTES=$(( D_READ * 8192 ))
    echo "Instance-wide (pg_stat_io, all backend types):"
    echo "  reads:    $(awk -v r="$D_READ" -v s="$ELAPSED" 'BEGIN{printf "%.0f", r/s}')/s"
    echo "  writes:   $(awk -v w="$D_WRITE" -v s="$ELAPSED" 'BEGIN{printf "%.0f", w/s}')/s"
    echo "  extends:  $(awk -v e="$D_EXT" -v s="$ELAPSED" 'BEGIN{printf "%.0f", e/s}')/s"
    echo -e "  ${YELLOW}total:    ${TOTAL_IOPS} IOPS${NC}   ($(mbps "$(( (D_READ + D_WRITE + D_EXT) * 8192 ))" "$ELAPSED") MB/s of block IO)"
    echo -e "  physical reads: ${YELLOW}$(mbps "$PHYS_BYTES" "$ELAPSED") MB/s${NC}"
    if [ "${IO_WAITS:-0}" -gt 0 ] 2>/dev/null && [ "${READ_IOPS:-0}" -gt 0 ] 2>/dev/null; then
        PER_READ_MS=$(awk -v w="$IO_WAITS" -v r="$READ_IOPS" 'BEGIN{printf "%.1f", (w / r) * 1000}')
        echo "  implied read latency: ~${PER_READ_MS} ms  ($IO_WAITS readers blocked at ${READ_IOPS} reads/s)"
        echo "  (cloud SSD normally serves an 8 KB read in 0.5-2 ms)"
    fi
else
    D_BLKS=$(( ${BLKS_2:-0} - ${BLKS_1:-0} ))
    [ "$D_BLKS" -ge 0 ] || D_BLKS=0
    PHYS_BYTES=$(( D_BLKS * 8192 ))
    echo "pg_stat_io needs PostgreSQL 16+; using pg_stat_database.blks_read instead."
    echo "  block reads (this database): $(awk -v b="$D_BLKS" -v s="$ELAPSED" 'BEGIN{printf "%.0f", b/s}')/s"
    echo -e "  physical reads: ${YELLOW}$(mbps "$PHYS_BYTES" "$ELAPSED") MB/s${NC}"
fi

CACHE_HIT=$(run_scalar "SELECT round(100.0*blks_hit/nullif(blks_hit+blks_read,0),1) FROM pg_stat_database WHERE datname = current_database()")
[ -n "$CACHE_HIT" ] && echo "  cache hit ratio (cumulative): ${CACHE_HIT}%"
echo ""

# ── 4. Expansion factor and transfer projection ──
echo "────────────────────────────────────────────────────────────────"
echo "4. DATA EXPANSION AND TRANSFER SIZE"
echo "────────────────────────────────────────────────────────────────"
EXPANSION=""
if [ "$COPY_DELTA" -gt 0 ] && [ "$PHYS_BYTES" -gt 0 ]; then
    EXPANSION=$(ratio "$COPY_DELTA" "$PHYS_BYTES")
    echo "Measured expansion: ${EXPANSION}x  (COPY output ${COPY_MBPS} MB/s vs physical reads $(mbps "$PHYS_BYTES" "$ELAPSED") MB/s)"
    echo ""
    echo "  TOAST is compressed on disk; COPY output is not. On-disk size understates"
    echo "  what crosses the wire by this factor."
else
    echo "Not enough movement in the sample to measure expansion."
    echo "  Re-run with a longer --sample-secs while a copy is active."
fi

TABLE_BYTES=$(run_scalar "SELECT coalesce(sum(pg_table_size(c.oid)),0)
                            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                           WHERE c.relkind IN ('r','p') AND c.relpersistence = 'p'
                             AND n.nspname NOT IN ('pg_catalog','information_schema','pgcopydb')
                             AND n.nspname NOT LIKE 'pg\\_%'")
if [ -n "$TABLE_BYTES" ] && [ "$TABLE_BYTES" -gt 0 ] 2>/dev/null; then
    echo ""
    echo "Table data on disk (heap + TOAST, no indexes): $(awk -v b="$TABLE_BYTES" 'BEGIN{printf "%.2f", b/1099511627776}') TB"
    if [ -n "$EXPANSION" ]; then
        WIRE=$(awk -v b="$TABLE_BYTES" -v x="$EXPANSION" 'BEGIN{printf "%.0f", b*x}')
        echo "Projected wire volume:                        $(awk -v b="$WIRE" 'BEGIN{printf "%.2f", b/1099511627776}') TB"
        if [ "$COPY_DELTA" -gt 0 ]; then
            HOURS=$(awk -v b="$WIRE" -v r="$COPY_DELTA" -v s="$ELAPSED" 'BEGIN{ rate=r/s; if (rate>0) printf "%.1f", b/rate/3600; else printf "0" }')
            echo -e "Full-copy time at current rate:               ${YELLOW}${HOURS} hours${NC} ($(awk -v h="$HOURS" 'BEGIN{printf "%.1f", h/24}') days)"
            echo ""
            echo "  This is a from-scratch estimate for all table data. For actual"
            echo "  remaining work, use ~/check-migration-status.sh."
        fi
    fi
fi
echo ""

# ── 5. Where the bulk lives ──
echo "────────────────────────────────────────────────────────────────"
echo "5. LARGEST TABLES  (TOAST-heavy tables dominate copy time)"
echo "────────────────────────────────────────────────────────────────"
run_table "SELECT n.nspname||'.'||c.relname AS table,
                  pg_size_pretty(pg_relation_size(c.oid)) AS heap,
                  pg_size_pretty(coalesce(pg_total_relation_size(c.reltoastrelid),0)) AS toast,
                  pg_size_pretty(pg_table_size(c.oid)) AS total
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r','p') AND c.relpersistence = 'p'
              AND n.nspname NOT IN ('pg_catalog','information_schema','pgcopydb')
            ORDER BY pg_table_size(c.oid) DESC
            LIMIT 10"
echo ""
echo "  A table whose TOAST dwarfs its heap is read-latency bound: few rows, huge"
echo "  payload. Make sure SPLIT_TABLES_LARGER_THAN is set so it copies in parts."
echo "  Do not use --estimate-table-sizes; it sizes parts on heap only and such a"
echo "  table would stop splitting."
echo ""

# ── 6. Replication slot health ──
echo "────────────────────────────────────────────────────────────────"
echo "6. REPLICATION SLOT  (WAL retention on the source)"
echo "────────────────────────────────────────────────────────────────"
run_table "SELECT slot_name, active,
                  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
             FROM pg_replication_slots ORDER BY slot_name"
SLOT_INACTIVE=$(run_scalar "SELECT count(*) FROM pg_replication_slots WHERE NOT active AND slot_name LIKE 'pgcopydb%'")
SLOT_INACTIVE=$(echo "${SLOT_INACTIVE:-0}" | tr -d '[:space:]')
MAX_KEEP=$(run_scalar "SELECT current_setting('max_slot_wal_keep_size')")
echo ""
echo "max_slot_wal_keep_size: ${MAX_KEEP:-unknown}"
if [ "${SLOT_INACTIVE:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "${RED}✗ A pgcopydb slot is INACTIVE — WAL is accumulating on the source.${NC}"
    echo "  Restart the follow process before the source disk fills."
fi
if [ "${MAX_KEEP:-}" = "-1" ]; then
    echo -e "${YELLOW}  max_slot_wal_keep_size is -1: WAL growth is unbounded if the slot stalls.${NC}"
fi
echo ""

# ── 7. Connection headroom ──
echo "────────────────────────────────────────────────────────────────"
echo "7. CONNECTION HEADROOM  (before raising TABLE_JOBS)"
echo "────────────────────────────────────────────────────────────────"
run_table "SELECT current_setting('max_connections') AS max_connections,
                  count(*) AS in_use,
                  count(*) FILTER (WHERE usename = current_user) AS this_role
             FROM pg_stat_activity"
echo ""

# ── 8. Network path ──
echo "────────────────────────────────────────────────────────────────"
echo "8. NETWORK PATH"
echo "────────────────────────────────────────────────────────────────"
SRC_HOST=$(echo "$PGCOPYDB_SOURCE_PGURI" | sed -E 's|^[a-z]+://||; s|^[^@]*@||; s|[/?].*$||; s|:[0-9]+$||')
SRC_PORT=$(echo "$PGCOPYDB_SOURCE_PGURI" | sed -nE 's|^[a-z]+://[^@]*@[^:/]+:([0-9]+).*$|\1|p')
SRC_PORT="${SRC_PORT:-5432}"
echo "Source endpoint: ${SRC_HOST}:${SRC_PORT}"

SRC_ADDRS=$(getent ahosts "$SRC_HOST" 2>/dev/null | awk '{print $1}' | sort -u || true)
SS_FILTER=""
for addr in $SRC_ADDRS; do
    [[ "$addr" == *:* ]] && addr="[$addr]"
    SS_FILTER="${SS_FILTER:+$SS_FILTER or }dst $addr:$SRC_PORT"
done

if ! command -v ss >/dev/null 2>&1; then
    echo "  (ss not available; skipping socket statistics)"
elif [ -z "$SS_FILTER" ]; then
    echo "  (could not resolve ${SRC_HOST}; skipping socket statistics)"
else
    SS_OUT=$(ss -tin "( $SS_FILTER )" 2>/dev/null || true)
    if [ -n "$SS_OUT" ]; then
        echo "$SS_OUT" | awk '
            /rtt:/ {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^rtt:/)     { split(substr($i,5), a, "/"); rtt_sum += a[1]; rtt_n++ }
                    if ($i ~ /^retrans:/) { split(substr($i,9), b, "/"); retr += b[2] }
                }
            }
            END {
                if (rtt_n > 0) printf "  connections: %d   avg RTT: %.1f ms   retransmits: %d\n", rtt_n, rtt_sum/rtt_n, retr+0
                else print "  no established connections to the source port"
            }'
        echo ""
        echo "  Stable RTT with zero retransmits means the path is clean. If workers are"
        echo "  slow anyway, the sender is not filling the pipe — look at section 1."
    else
        echo "  No established connections found to ${SRC_HOST}:${SRC_PORT}."
    fi
fi

if [ "$WIRE_TEST" = true ]; then
    echo ""
    echo "Wire throughput test (500MB generated on the source, no disk reads):"
    WIRE_START=$(date +%s)
    PGOPTIONS="$PGOPTS" psql "$PGCOPYDB_SOURCE_PGURI" -X -q \
        -c "COPY (SELECT repeat('x',1000) FROM generate_series(1,500000)) TO STDOUT" > /dev/null 2>&1 || true
    WIRE_END=$(date +%s)
    WIRE_SECS=$(( WIRE_END - WIRE_START ))
    [ "$WIRE_SECS" -gt 0 ] || WIRE_SECS=1
    echo -e "  ${YELLOW}$(mbps 500500000 "$WIRE_SECS") MB/s per connection${NC} (500MB in ${WIRE_SECS}s)"
    echo ""
    echo "  Compare against section 2. If a single test connection carries far more"
    echo "  than a COPY worker does, the workers are storage bound, not network bound."
    echo "  A low number here with a clean RTT points at a proxy or bandwidth cap."
else
    echo ""
    echo "  Re-run with --wire-test to measure per-connection network throughput."
    echo "  It streams ~500MB from the source, so it adds load."
fi
echo ""

# ── Summary ──
echo "════════════════════════════════════════════════════════════════"
echo "SUMMARY"
echo "════════════════════════════════════════════════════════════════"
if [ "${WORKERS:-0}" -eq 0 ] 2>/dev/null; then
    echo -e "${YELLOW}No copy sessions were running${NC} — nothing to diagnose. Start the migration"
    echo "or check ~/check-migration-status.sh."
elif [ "${LOCK_WAITS:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "${RED}Lock contention on the source${NC} — $LOCK_WAITS session(s) waiting on a lock."
    echo "The copy is competing with the application workload. See section 1."
elif [ "${IO_WAITS:-0}" -ge "${CLIENT_WAITS:-0}" ] 2>/dev/null && [ "${IO_WAITS:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "${YELLOW}Source storage is the constraint${NC} — $IO_WAITS of $WORKERS sessions blocked on disk."
    echo "Raising TABLE_JOBS helps only if the volume has IOPS headroom. Compare the"
    echo "IOPS in section 3 against the provider's documented allowance:"
    echo "  - well under the allowance  -> raise TABLE_JOBS, re-run, confirm IOPS rose"
    echo "  - at the allowance, or flat after raising TABLE_JOBS -> storage tier is the"
    echo "    only lever; take section 3 and section 4 to the database owner"
elif [ "${CLIENT_WAITS:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "${YELLOW}The source is waiting on the consumer or the network${NC} — $CLIENT_WAITS in ClientWrite."
    echo "Check section 8. Run with --wire-test to measure the per-connection ceiling."
else
    echo -e "${GREEN}No dominant wait${NC} — the source sessions are running, so it is CPU bound"
    echo "or the sample caught a quiet moment. Re-run with a longer --sample-secs."
fi
echo ""
echo "Related: ~/check-migration-status.sh (progress), ~/check-copy-stall.sh (target side)"
echo ""
