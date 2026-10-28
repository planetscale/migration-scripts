#!/bin/bash
#
# Usage: ~/check-copy-progress.sh [--no-target]
#        MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/check-copy-progress.sh
#
# Shows how much data is left for each running pgcopydb COPY task. Wraps
# `pgcopydb list progress`, then measures each running table or split part
# in rows: rows copied so far (pg_stat_progress_copy on the source) against
# the planner's row estimate for the part's WHERE clause (EXPLAIN on the
# source). Also shows bytes sent, row rate, and an estimated time to finish.
#
# Rows, not bytes: split parts are equal key ranges, not equal data sizes,
# and COPY text is uncompressed while pg_table_size() includes compressed
# TOAST. A byte comparison can be off by several times on large tables.
#
#   --no-target   Skip the target size query.
#
# Read-only: opens the SQLite catalog with -readonly and connects with
# default_transaction_read_only=on and a statement timeout. EXPLAIN does not
# run the query. Run it from the migration instance.
#
# Requires: PGCOPYDB_SOURCE_PGURI, PGCOPYDB_TARGET_PGURI (from ~/.env)
#
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Options ---
QUERY_TARGET=true
while [ $# -gt 0 ]; do
    case "$1" in
        --no-target) QUERY_TARGET=false; shift ;;
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

# --- Locate the migration directory and its SQLite catalog ---
MIGRATION_DIR="${MIGRATION_DIR:-$(ls -dt ~/migration_*/ 2>/dev/null | head -1 || true)}"
MIGRATION_DIR="${MIGRATION_DIR%/}"
if [ -z "$MIGRATION_DIR" ]; then
    echo -e "${RED}✗ No ~/migration_* directory found. Set MIGRATION_DIR.${NC}"
    exit 1
fi

SOURCE_DB="$MIGRATION_DIR/schema/source.db"
if [ ! -f "$SOURCE_DB" ]; then
    echo -e "${RED}✗ $SOURCE_DB not found. Has STEP 1 (catalog) finished?${NC}"
    exit 1
fi

# -readonly guarantees this script cannot change the catalog that the running
# pgcopydb process writes to.
sql() { sqlite3 -readonly -separator $'\x1f' "$SOURCE_DB" "$1"; }

# Read-only, time-bounded psql. SQL goes in on stdin so that psql expands
# :'var' variables, which -c does not do.
PGOPTS='-c default_transaction_read_only=on -c statement_timeout=30000 -c lock_timeout=5000'
src_scalar() { PGOPTIONS="$PGOPTS" psql "$PGCOPYDB_SOURCE_PGURI" -X -q -t -A "$@" 2>/dev/null || echo ""; }

human_rows() { awk -v n="$1" 'BEGIN { if (n >= 1e9) printf "%.2fB", n/1e9; else if (n >= 1e6) printf "%.1fM", n/1e6; else if (n >= 1e3) printf "%.1fK", n/1e3; else printf "%d", n }'; }
human_secs() { awk -v s="$1" 'BEGIN { s = int(s); printf "%dh%02dm", s/3600, (s%3600)/60 }'; }

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  PlanetScale Migration — COPY Progress                          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Migration Directory: $MIGRATION_DIR"
echo "Generated:           $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

# ── 1. pgcopydb's own view: table and index counts ──
echo "────────────────────────────────────────────────────────────────"
echo "1. PGCOPYDB LIST PROGRESS"
echo "────────────────────────────────────────────────────────────────"
if ! pgcopydb list progress --dir "$MIGRATION_DIR" 2>/dev/null; then
    echo -e "${YELLOW}pgcopydb list progress failed. Continuing with the SQLite catalog.${NC}"
fi
echo ""
echo "  The Bytes row compares COPY text sent (Done, In Progress) with on-disk"
echo "  size (Total). Use the counts, not the Bytes row, to judge progress."
echo ""

# ── 2. Per-task progress in rows ──
echo "────────────────────────────────────────────────────────────────"
echo "2. RUNNING COPY TASKS  (rows copied vs planner estimate, source)"
echo "────────────────────────────────────────────────────────────────"

# summary.command is "COPY <qname>[ <where clause>]", and the source COPY
# query is "copy (SELECT ... FROM ONLY <qname>[ <where clause>]) to stdout",
# so the WHERE clause both finds the source session and feeds EXPLAIN.
RUNNING_TASKS=$(sql "
    SELECT t.qname,
           CASE WHEN coalesce(p.partcount, 1) > 1 THEN s.partnum || '/' || p.partcount ELSE '-' END,
           s.pid,
           coalesce(s.bytes, 0),
           max(strftime('%s','now') - s.start_time_epoch, 1),
           substr(s.command, length('COPY ' || t.qname) + 2)
    FROM summary s
    JOIN s_table t ON t.oid = s.tableoid
    LEFT JOIN s_table_part p ON p.oid = s.tableoid AND p.partnum = s.partnum
    WHERE s.tableoid IS NOT NULL
      AND s.start_time_epoch IS NOT NULL
      AND s.done_time_epoch IS NULL
    ORDER BY s.start_time_epoch;" 2>/dev/null || echo "")

if [ -z "$RUNNING_TASKS" ]; then
    echo -e "${GREEN}✓ No COPY tasks are running.${NC}"
else
    FMT="%-32s %-6s %-7s %-10s %-10s %-10s %-6s %-9s %-8s %-9s\n"
    # shellcheck disable=SC2059
    printf "$FMT" table part pid sent copied est_rows pct rows/s elapsed eta
    # shellcheck disable=SC2059
    printf "$FMT" "--------------------------------" "------" "-------" "----------" "----------" "----------" "------" "---------" "--------" "---------"

    while IFS=$'\x1f' read -r QNAME PART PID SENT ELAPSED WHERE; do
        [ -z "$QNAME" ] && continue

        if [ -n "$WHERE" ]; then
            NEEDLE="FROM ONLY $QNAME $WHERE)"
        else
            NEEDLE="FROM ONLY $QNAME)"
        fi

        COPIED=$(src_scalar -v needle="$NEEDLE" <<'SQL'
SELECT p.tuples_processed
FROM pg_stat_progress_copy p
JOIN pg_stat_activity a USING (pid)
WHERE p.command = 'COPY TO'
  AND strpos(a.query, :'needle') > 0
ORDER BY a.query_start
LIMIT 1;
SQL
)
        EST=$(src_scalar <<<"EXPLAIN (FORMAT JSON) SELECT 1 FROM ONLY $QNAME $WHERE;" \
              | grep -o '"Plan Rows": *[0-9]*' | head -1 | grep -o '[0-9]*$' || true)

        SENT_GB=$(awk -v b="$SENT" 'BEGIN { printf "%.1f GB", b / 1073741824 }')
        COPIED_H="-"; EST_H="-"; PCT="-"; RATE="-"; ETA="-"
        [ -n "$EST" ] && EST_H=$(human_rows "$EST")
        if [ -n "$COPIED" ]; then
            COPIED_H=$(human_rows "$COPIED")
            RATE=$(awk -v r="$COPIED" -v e="$ELAPSED" 'BEGIN { printf "%.0f", r / e }')
            if [ -n "$EST" ] && [ "$EST" -gt 0 ]; then
                PCT=$(awk -v r="$COPIED" -v n="$EST" 'BEGIN { printf "%.0f%%", 100 * r / n }')
                if [ "$COPIED" -ge "$EST" ]; then
                    ETA="past est."
                elif [ "$COPIED" -gt 0 ]; then
                    ETA=$(human_secs "$(awk -v r="$COPIED" -v n="$EST" -v e="$ELAPSED" 'BEGIN { print (n - r) * e / r }')")
                fi
            fi
        fi

        # shellcheck disable=SC2059
        printf "$FMT" "$QNAME" "$PART" "$PID" "$SENT_GB" "$COPIED_H" "$EST_H" "$PCT" "$RATE" "$(human_secs "$ELAPSED")" "$ETA"
    done <<<"$RUNNING_TASKS"

    echo ""
    echo "  copied: rows the source COPY has sent (pg_stat_progress_copy)."
    echo "  est_rows: planner estimate for the part's WHERE clause (EXPLAIN)."
    echo "  '-' in copied means the source session is not visible to this role."
    echo "  eta assumes the average row rate since the task started."
fi
echo ""

# ── 3. Work not started yet ──
echo "────────────────────────────────────────────────────────────────"
echo "3. COPY TASKS NOT STARTED"
echo "────────────────────────────────────────────────────────────────"
NOT_STARTED=$(sql "
    WITH tasks AS (
        SELECT t.oid, coalesce(p.partnum, 0) AS partnum
        FROM s_table t
        LEFT JOIN s_table_part p ON p.oid = t.oid
        WHERE coalesce(t.exclude_data, 0) = 0
    )
    SELECT count(*)
    FROM tasks k
    LEFT JOIN summary s ON s.tableoid = k.oid AND s.partnum = k.partnum
    WHERE s.start_time_epoch IS NULL;" 2>/dev/null || echo "")
if [ "${NOT_STARTED:-}" = "0" ]; then
    echo -e "${GREEN}✓ Every table and part has started.${NC} Only the tasks in section 2 are left."
elif [ -n "$NOT_STARTED" ]; then
    echo "  $NOT_STARTED table(s) or part(s) have not started."
else
    echo -e "${YELLOW}  Could not read the task list from the catalog.${NC}"
fi
echo ""

# ── 4. Optional: current target storage ──
if [ "$QUERY_TARGET" = true ]; then
    echo "────────────────────────────────────────────────────────────────"
    echo "4. TARGET SIZE"
    echo "────────────────────────────────────────────────────────────────"
    if [ -z "${PGCOPYDB_TARGET_PGURI:-}" ]; then
        echo -e "${YELLOW}  PGCOPYDB_TARGET_PGURI is not set. Skipping.${NC}"
    else
        # pg_ls_waldir() needs pg_monitor, so fall back to the database size
        # alone if the role does not have it.
        PGOPTIONS="$PGOPTS" psql "$PGCOPYDB_TARGET_PGURI" -X -q -P pager=off -P footer=off -c "
            SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size,
                   (SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir()) AS wal_size;" 2>/dev/null \
        || PGOPTIONS="$PGOPTS" psql "$PGCOPYDB_TARGET_PGURI" -X -q -P pager=off -P footer=off -c "
            SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;" \
        || echo -e "${YELLOW}  Could not query the target.${NC}"
    fi
    echo ""
fi
