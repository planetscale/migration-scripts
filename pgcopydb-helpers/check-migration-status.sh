#!/bin/bash
#
# Usage: ~/check-migration-status.sh
#
# Displays a dashboard of pgcopydb migration progress: phase status,
# table/index/constraint copy progress, CDC streaming, errors, and
# active database operations. Reads from the most recent ~/migration_*
# directory and queries the SQLite catalogs for accurate counts.
#
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  PlanetScale Migration Status Report                           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# --- Load environment ---
set +u
set -a
source ~/.env
set +a
set -u

MIGRATION_DIR=$(ls -dt ~/migration_* 2>/dev/null | head -1)
if [ -z "$MIGRATION_DIR" ]; then
    echo -e "${RED}✗ No migration directory found${NC}"
    exit 1
fi

echo "════════════════════════════════════════════════════════════════"
echo "                    MIGRATION STATUS SUMMARY"
echo "════════════════════════════════════════════════════════════════"
echo ""

START_TIME=$(stat -c %y "$MIGRATION_DIR" 2>/dev/null | cut -d'.' -f1 || stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$MIGRATION_DIR" 2>/dev/null)
echo "Migration Directory: $MIGRATION_DIR"
echo "Started: $START_TIME"
echo ""

RUNNING_PROCS=$(ps aux | grep "[p]gcopydb.*clone" | wc -l | xargs)

if [ -f "$MIGRATION_DIR/migration.log" ]; then
    if grep -q "Migration SUCCEEDED\|All step are now done" "$MIGRATION_DIR/migration.log" 2>/dev/null; then
        echo -e "${GREEN}Status: COMPLETED${NC}"
        MIGRATION_COMPLETE=true
    elif [ "$RUNNING_PROCS" -gt 0 ]; then
        echo -e "${GREEN}Status: RUNNING${NC} ($RUNNING_PROCS pgcopydb processes active)"
        MIGRATION_COMPLETE=false
    else
        echo -e "${YELLOW}Status: NOT RUNNING${NC} (may be stopped or failed)"
        MIGRATION_COMPLETE=false
    fi
else
    echo -e "${YELLOW}Status: Unknown${NC}"
    MIGRATION_COMPLETE=false
fi
echo ""

# Get actual counts for determining phase completion
# With --split-tables-larger-than, split tables have multiple parts tracked in s_table_part.
# Each part is a separate copy task. Count total copy tasks = (non-split tables) + (split parts).
SPLIT_TABLES=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(DISTINCT oid) FROM s_table_part;" 2>/dev/null || echo "0")
SPLIT_PARTS=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(*) FROM s_table_part;" 2>/dev/null || echo "0")
NONSPLIT_TABLES=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(*) FROM s_table t WHERE NOT EXISTS (SELECT 1 FROM s_table_part p WHERE p.oid = t.oid);" 2>/dev/null || echo "0")
TABLES_TOTAL=$((NONSPLIT_TABLES + SPLIT_PARTS))
TABLES_STARTED=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(*) FROM summary WHERE tableoid IS NOT NULL AND start_time_epoch IS NOT NULL;" 2>/dev/null || echo "0")
TABLES_DONE=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(*) FROM summary WHERE tableoid IS NOT NULL AND done_time_epoch IS NOT NULL;" 2>/dev/null || echo "0")
TABLES_IN_PROGRESS=$((TABLES_STARTED - TABLES_DONE))

# Calculate data transferred for tables
BYTES_TRANSFERRED=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COALESCE(SUM(bytes), 0) FROM summary WHERE tableoid IS NOT NULL;" 2>/dev/null || echo "0")
GB_TRANSFERRED=$(echo "scale=2; $BYTES_TRANSFERRED / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")

INDEXES_TOTAL=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(*) FROM s_index;" 2>/dev/null || echo "0")
INDEXES_STARTED=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(DISTINCT indexoid) FROM summary WHERE indexoid IS NOT NULL AND start_time_epoch IS NOT NULL;" 2>/dev/null || echo "0")
INDEXES_DONE=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(DISTINCT indexoid) FROM summary WHERE indexoid IS NOT NULL AND done_time_epoch IS NOT NULL;" 2>/dev/null || echo "0")
INDEXES_IN_PROGRESS=$((INDEXES_STARTED - INDEXES_DONE))

CONSTRAINTS_TOTAL=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(*) FROM s_constraint;" 2>/dev/null || echo "0")
CONSTRAINTS_STARTED=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(DISTINCT conoid) FROM summary WHERE conoid IS NOT NULL AND start_time_epoch IS NOT NULL;" 2>/dev/null || echo "0")
CONSTRAINTS_DONE=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(DISTINCT conoid) FROM summary WHERE conoid IS NOT NULL AND done_time_epoch IS NOT NULL;" 2>/dev/null || echo "0")
CONSTRAINTS_IN_PROGRESS=$((CONSTRAINTS_STARTED - CONSTRAINTS_DONE))

echo "────────────────────────────────────────────────────────────────"
echo "MIGRATION PHASES"
echo "────────────────────────────────────────────────────────────────"

STEP1=$(grep -q "Fetched information for.*tables" "$MIGRATION_DIR/migration.log" 2>/dev/null && echo "done" || echo "pending")
STEP2=$(grep -q "STEP 2: dump the source database schema" "$MIGRATION_DIR/migration.log" 2>/dev/null && grep -q "pg_dump.*post-data" "$MIGRATION_DIR/migration.log" 2>/dev/null && echo "done" || (grep -q "STEP 2:" "$MIGRATION_DIR/migration.log" 2>/dev/null && echo "running" || echo "pending"))
STEP3=$(grep -q "STEP 3: restore the pre-data section" "$MIGRATION_DIR/migration.log" 2>/dev/null && grep -q "errors ignored on restore:\|Skipping pre-data" "$MIGRATION_DIR/migration.log" 2>/dev/null && echo "done" || (grep -q "STEP 3:" "$MIGRATION_DIR/migration.log" 2>/dev/null && echo "running" || echo "pending"))

if [ "$TABLES_TOTAL" -gt 0 ] && [ "$TABLES_DONE" -eq "$TABLES_TOTAL" ]; then
    STEP4="done"
elif [ "$TABLES_STARTED" -gt 0 ]; then
    STEP4="running"
else
    STEP4="pending"
fi

if [ "$INDEXES_TOTAL" -gt 0 ] && [ "$INDEXES_DONE" -eq "$INDEXES_TOTAL" ]; then
    STEP6="done"
elif [ "$INDEXES_STARTED" -gt 0 ]; then
    STEP6="running"
else
    STEP6="pending"
fi

if [ "$CONSTRAINTS_TOTAL" -gt 0 ] && [ "$CONSTRAINTS_DONE" -eq "$CONSTRAINTS_TOTAL" ]; then
    STEP7="done"
elif [ "$CONSTRAINTS_STARTED" -gt 0 ]; then
    STEP7="running"
else
    STEP7="pending"
fi

STEP8=$(grep -q "STEP 8:.*VACUUM" "$MIGRATION_DIR/migration.log" 2>/dev/null && grep -q "VACUUM.*done" "$MIGRATION_DIR/migration.log" 2>/dev/null && echo "done" || (grep -q "VACUUM" "$MIGRATION_DIR/migration.log" 2>/dev/null && echo "running" || echo "pending"))
STEP9=$(grep -q "STEP 9: reset sequences" "$MIGRATION_DIR/migration.log" 2>/dev/null && echo "done" || echo "pending")
STEP10=$(grep -q "restore.*post-data" "$MIGRATION_DIR/migration.log" 2>/dev/null && grep -q "REFRESH MATERIALIZED VIEW" "$MIGRATION_DIR/migration.log" 2>/dev/null && echo "done" || (grep -q "post-data" "$MIGRATION_DIR/migration.log" 2>/dev/null && echo "running" || echo "pending"))

status_icon() {
    case "$1" in
        done) echo -e "${GREEN}[done]${NC}" ;;
        running) echo -e "${YELLOW}[run]${NC}" ;;
        pending) echo -e "[ -- ]" ;;
    esac
}

echo -e "  $(status_icon $STEP1) Phase 1: Catalog source database"
echo -e "  $(status_icon $STEP2) Phase 2: Dump schema from source"
echo -e "  $(status_icon $STEP3) Phase 3: Restore schema to target"

if [ "$TABLES_IN_PROGRESS" -gt 0 ]; then
    echo -e "  $(status_icon $STEP4) Phase 4: Copy table data ($TABLES_IN_PROGRESS in progress, $TABLES_DONE/$TABLES_TOTAL copy tasks complete)"
else
    echo -e "  $(status_icon $STEP4) Phase 4: Copy table data ($TABLES_DONE/$TABLES_TOTAL copy tasks complete)"
fi

if [ "$INDEXES_IN_PROGRESS" -gt 0 ]; then
    echo -e "  $(status_icon $STEP6) Phase 6: Create indexes ($INDEXES_IN_PROGRESS in progress, $INDEXES_DONE/$INDEXES_TOTAL complete)"
else
    echo -e "  $(status_icon $STEP6) Phase 6: Create indexes ($INDEXES_DONE/$INDEXES_TOTAL complete)"
fi

if [ "$CONSTRAINTS_IN_PROGRESS" -gt 0 ]; then
    echo -e "  $(status_icon $STEP7) Phase 7: Create constraints ($CONSTRAINTS_IN_PROGRESS in progress, $CONSTRAINTS_DONE/$CONSTRAINTS_TOTAL complete)"
else
    echo -e "  $(status_icon $STEP7) Phase 7: Create constraints ($CONSTRAINTS_DONE/$CONSTRAINTS_TOTAL complete)"
fi

echo -e "  $(status_icon $STEP8) Phase 8: Vacuum and analyze"
echo -e "  $(status_icon $STEP9) Phase 9: Reset sequences"
echo -e "  $(status_icon $STEP10) Phase 10: Post-data (materialized views)"
echo ""

echo "────────────────────────────────────────────────────────────────"
echo "PROGRESS DETAILS"
echo "────────────────────────────────────────────────────────────────"

TABLES_PCT=0
if [ "$TABLES_TOTAL" -gt 0 ]; then
    TABLES_PCT=$(echo "scale=1; 100 * $TABLES_DONE / $TABLES_TOTAL" | bc 2>/dev/null || echo "0")
fi
SPLIT_INFO=""
if [ "$SPLIT_PARTS" -gt 0 ]; then
    SPLIT_INFO=" (incl $SPLIT_PARTS parts from $SPLIT_TABLES split tables)"
fi
if [ "$TABLES_IN_PROGRESS" -gt 0 ]; then
    echo "Copy tasks:  $TABLES_IN_PROGRESS in progress, $TABLES_DONE/$TABLES_TOTAL complete ($TABLES_PCT%)${SPLIT_INFO}"
    echo "Data:        $GB_TRANSFERRED GB transferred"
else
    echo "Copy tasks:  $TABLES_DONE/$TABLES_TOTAL ($TABLES_PCT%)${SPLIT_INFO}"
fi

INDEXES_PCT=0
if [ "$INDEXES_TOTAL" -gt 0 ]; then
    INDEXES_PCT=$(echo "scale=1; 100 * $INDEXES_DONE / $INDEXES_TOTAL" | bc 2>/dev/null || echo "0")
fi
if [ "$INDEXES_IN_PROGRESS" -gt 0 ]; then
    echo "Indexes:     $INDEXES_IN_PROGRESS in progress, $INDEXES_DONE/$INDEXES_TOTAL complete ($INDEXES_PCT%)"
else
    echo "Indexes:     $INDEXES_DONE/$INDEXES_TOTAL ($INDEXES_PCT%)"
fi

CONSTRAINTS_PCT=0
if [ "$CONSTRAINTS_TOTAL" -gt 0 ]; then
    CONSTRAINTS_PCT=$(echo "scale=1; 100 * $CONSTRAINTS_DONE / $CONSTRAINTS_TOTAL" | bc 2>/dev/null || echo "0")
fi
if [ "$CONSTRAINTS_IN_PROGRESS" -gt 0 ]; then
    echo "Constraints: $CONSTRAINTS_IN_PROGRESS in progress, $CONSTRAINTS_DONE/$CONSTRAINTS_TOTAL complete ($CONSTRAINTS_PCT%)"
else
    echo "Constraints: $CONSTRAINTS_DONE/$CONSTRAINTS_TOTAL ($CONSTRAINTS_PCT%)"
fi

# Vacuum progress
VACUUM_TOTAL=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(*) FROM s_table;" 2>/dev/null || echo "0")
VACUUM_DONE=$(sqlite3 "$MIGRATION_DIR/schema/source.db" "SELECT COUNT(*) FROM vacuum_summary WHERE done_time_epoch > 0;" 2>/dev/null || echo "0")
VACUUM_DONE=$((VACUUM_DONE + 0))
VACUUM_PCT=0
if [ "$VACUUM_TOTAL" -gt 0 ]; then
    VACUUM_PCT=$(echo "scale=1; 100 * $VACUUM_DONE / $VACUUM_TOTAL" | bc 2>/dev/null || echo "0")
fi
echo "Vacuum:      $VACUUM_DONE/$VACUUM_TOTAL ($VACUUM_PCT%)"

# Post-data restore progress
POSTDATA_STATUS="pending"
if grep -q "STEP 5: restore the post-data" "$MIGRATION_DIR/migration.log" 2>/dev/null; then
    if grep -q "All step are now done\|post-data.*done" "$MIGRATION_DIR/migration.log" 2>/dev/null; then
        POSTDATA_STATUS="complete"
    else
        POSTDATA_STATUS="in progress"
    fi
fi
echo "Post-data:   $POSTDATA_STATUS"

# CDC streaming progress
if [ -d "$MIGRATION_DIR/cdc" ]; then
    CDC_FILES=$(ls -1 "$MIGRATION_DIR/cdc/"*.sql 2>/dev/null | wc -l | xargs)
    if [ "$CDC_FILES" -gt 0 ]; then
        LAST_LSN=$(grep "Reported write_lsn" "$MIGRATION_DIR/migration.log" 2>/dev/null | tail -1 | grep -oP 'write_lsn \K[0-9A-Fa-f]+/[0-9A-Fa-f]+' || true)
        echo "CDC files:   $CDC_FILES SQL files transformed${LAST_LSN:+, streaming at $LAST_LSN}"
    fi
fi

# Error count — check all error sources
LOG_ERRORS=$(grep -c " ERROR " "$MIGRATION_DIR/migration.log" 2>/dev/null || echo "0")
LOG_ERRORS=$(echo "$LOG_ERRORS" | tr -d '[:space:]')
LOG_ERRORS=$((LOG_ERRORS + 0))
RESTORE_ERROR_LINE=$(grep "errors ignored on restore:" "$MIGRATION_DIR/migration.log" 2>/dev/null | tail -1)
RESTORE_ERRORS=$(echo "$RESTORE_ERROR_LINE" | sed -n 's/.*errors ignored on restore: \([0-9]\+\).*/\1/p')
RESTORE_ERRORS=$((${RESTORE_ERRORS:-0} + 0))

if [ "$LOG_ERRORS" -eq 0 ] && [ "$RESTORE_ERRORS" -eq 0 ]; then
    echo -e "Errors:      ${GREEN}0${NC}"
else
    if [ "$RESTORE_ERRORS" -gt 0 ]; then
        if [ "$RESTORE_ERRORS" -le 10 ]; then
            echo -e "Errors:      ${GREEN}$RESTORE_ERRORS pg_restore (within tolerance)${NC}"
        else
            echo -e "Errors:      ${RED}$RESTORE_ERRORS pg_restore (exceeds tolerance)${NC}"
        fi
    fi
    if [ "$LOG_ERRORS" -gt 0 ]; then
        LAST_LOG_ERROR=$(grep " ERROR " "$MIGRATION_DIR/migration.log" 2>/dev/null | tail -1 | cut -c1-120)
        echo -e "             ${RED}$LOG_ERRORS ERROR lines in log${NC}"
        echo "             Last: $LAST_LOG_ERROR"
    fi
fi

# Total runtime
DIR_EPOCH=$(stat -c %Y "$MIGRATION_DIR" 2>/dev/null || stat -f %m "$MIGRATION_DIR" 2>/dev/null)
NOW_EPOCH=$(date +%s)
ELAPSED=$((NOW_EPOCH - DIR_EPOCH))
printf "Runtime:     %dh %02dm %02ds\n" $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) $((ELAPSED%60))

echo ""
echo "────────────────────────────────────────────────────────────────"
echo "RECENT ACTIVITY (Last 10 log lines)"
echo "────────────────────────────────────────────────────────────────"
if [ -f "$MIGRATION_DIR/migration.log" ]; then
    tail -10 "$MIGRATION_DIR/migration.log" | sed 's/^/  /'
fi

echo ""
echo "════════════════════════════════════════════════════════════════"

# Overall completion
if [ "$TABLES_TOTAL" -gt 0 ] && [ "$INDEXES_TOTAL" -gt 0 ]; then
    OVERALL_ITEMS=$((TABLES_TOTAL + INDEXES_TOTAL + CONSTRAINTS_TOTAL))
    OVERALL_DONE=$((TABLES_DONE + INDEXES_DONE + CONSTRAINTS_DONE))
    if [ "$OVERALL_ITEMS" -gt 0 ]; then
        OVERALL_PCT=$(echo "scale=1; 100 * $OVERALL_DONE / $OVERALL_ITEMS" | bc 2>/dev/null || echo "0")
        echo "Overall Progress: $OVERALL_PCT%"
    fi
fi

echo ""
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"

echo ""
echo "────────────────────────────────────────────────────────────────"
echo "ACTIVE DATABASE OPERATIONS"
echo "────────────────────────────────────────────────────────────────"

# Check for active queries on target database
if [ -n "$PGCOPYDB_TARGET_PGURI" ]; then
    ACTIVE_QUERIES=$(psql "$PGCOPYDB_TARGET_PGURI" -t -A -F $'\t' -c "
        SELECT
            EXTRACT(EPOCH FROM (now() - query_start))::int as duration_secs,
            CASE
                WHEN query ~ 'REFRESH MATERIALIZED VIEW' THEN
                    regexp_replace(query, '.*REFRESH MATERIALIZED VIEW ([^;]+).*', 'REFRESH MATERIALIZED VIEW \1')
                WHEN query ~ 'COPY' THEN
                    regexp_replace(query, '.*COPY \"?([^\"]+)\"?.*', 'COPY \1')
                WHEN query ~ 'CREATE INDEX' THEN
                    regexp_replace(query, '.*CREATE (UNIQUE )?INDEX ([^ ]+).*', 'CREATE INDEX \2')
                WHEN query ~ 'ALTER TABLE' THEN
                    regexp_replace(query, '.*ALTER TABLE ([^ ]+).*', 'ALTER TABLE \1')
                WHEN query ~ 'VACUUM' THEN
                    regexp_replace(query, '.*VACUUM[^\"]*\"?([^\"]+)\"?.*', 'VACUUM \1')
                ELSE
                    LEFT(regexp_replace(query, E'[\\n\\r]+', ' ', 'g'), 60)
            END as operation
        FROM pg_stat_activity
        WHERE state = 'active'
          AND query NOT LIKE '%pg_stat_activity%'
          AND pid != pg_backend_pid()
        ORDER BY query_start ASC
        LIMIT 50;
    " 2>/dev/null)

    if [ -n "$ACTIVE_QUERIES" ]; then
        echo "$ACTIVE_QUERIES" | while IFS=$'\t' read -r duration operation; do
            [ -z "$duration" ] && continue
            duration=$((${duration:-0} + 0))
            if [ "$duration" -ge 3600 ] 2>/dev/null; then
                printf "  [%dh %02dm %02ds]  %s\n" $((duration/3600)) $(((duration%3600)/60)) $((duration%60)) "$operation"
            elif [ "$duration" -ge 60 ] 2>/dev/null; then
                printf "  [%dm %02ds]      %s\n" $((duration/60)) $((duration%60)) "$operation"
            else
                printf "  [%ds]          %s\n" "$duration" "$operation"
            fi
        done
    else
        echo "  No active queries on target database"
    fi
else
    echo "  (Target database URI not available)"
fi
