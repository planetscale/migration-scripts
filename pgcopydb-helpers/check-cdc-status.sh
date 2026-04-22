#!/bin/bash
#
# Usage: ~/check-cdc-status.sh
#
# Displays CDC replication progress: apply/streaming LSN positions, backlog
# gap in GB, apply rate, ETA to catch-up, and source replication slot health.
# Reads from the sentinel SQLite DB and queries the source via psql.
#
set -euo pipefail

# --- Load environment ---
set +u
set -a
source ~/.env
set +a
set -u

# --- Configuration ---
MIGRATION_DIR="${MIGRATION_DIR:-$(ls -dt ~/migration_*/ 2>/dev/null | head -1 || true)}"

if [ -z "$MIGRATION_DIR" ]; then
    echo "ERROR: No migration directory found"
    exit 1
fi

# Find the latest resume log (or migration.log)
RESUME_LOG=$(ls -t "$MIGRATION_DIR"/resume-*.log 2>/dev/null | head -1 || true)
LOG="${RESUME_LOG:-$MIGRATION_DIR/migration.log}"

# --- 1. Process check ---
PROCS=$(pgrep -a pgcopydb 2>/dev/null || true)
PROC_COUNT=$(echo "$PROCS" | grep -c pgcopydb 2>/dev/null || echo 0)

# --- 2. Get apply LSN from sentinel (source of truth) + log fallback ---
APPLY_LSN=""
APPLY_FILE=""
SENTINEL_REPLAY_LSN=""
if [ -f "$MIGRATION_DIR/schema/source.db" ]; then
    SENTINEL_REPLAY_LSN=$(sqlite3 "$MIGRATION_DIR/schema/source.db" \
        "SELECT replay_lsn FROM sentinel LIMIT 1;" 2>/dev/null || true)
fi
if [ -n "$SENTINEL_REPLAY_LSN" ] && [ "$SENTINEL_REPLAY_LSN" != "0/0" ]; then
    APPLY_LSN="$SENTINEL_REPLAY_LSN"
    APPLY_FILE="(from sentinel)"
else
    # Fallback: parse from log
    APPLY_LINE=$(grep "Apply reached" "$LOG" 2>/dev/null | tail -1 || true)
    if [ -n "$APPLY_LINE" ]; then
        APPLY_LSN=$(echo "$APPLY_LINE" | grep -oP '\b[0-9A-Fa-f]+/[0-9A-Fa-f]+\b' | head -1 || true)
        APPLY_FILE=$(echo "$APPLY_LINE" | grep -oP '/[^"]+\.sql' | head -1 || true)
        APPLY_FILE=$(basename "$APPLY_FILE" 2>/dev/null || true)
    fi
fi

# --- 3. Get streaming LSN from sentinel (source of truth) + log fallback ---
STREAM_LSN=""
SENTINEL_WRITE_LSN=""
if [ -f "$MIGRATION_DIR/schema/source.db" ]; then
    SENTINEL_WRITE_LSN=$(sqlite3 "$MIGRATION_DIR/schema/source.db" \
        "SELECT write_lsn FROM sentinel LIMIT 1;" 2>/dev/null || true)
fi
if [ -n "$SENTINEL_WRITE_LSN" ] && [ "$SENTINEL_WRITE_LSN" != "0/0" ]; then
    STREAM_LSN="$SENTINEL_WRITE_LSN"
else
    # Fallback: parse from log
    STREAM_LINE=$(grep "Reported write_lsn" "$LOG" 2>/dev/null | tail -1 || true)
    if [ -n "$STREAM_LINE" ]; then
        STREAM_LSN=$(echo "$STREAM_LINE" | grep -oP 'write_lsn \K[0-9A-Fa-f]+/[0-9A-Fa-f]+' || true)
    fi
fi

# --- 4. Check for errors ---
ERROR_COUNT=$(grep -c "ERROR" "$LOG" 2>/dev/null || true)
ERROR_COUNT=${ERROR_COUNT:-0}
LAST_ERROR=$(grep "ERROR" "$LOG" 2>/dev/null | tail -1 || true)

# --- 5. Compute gap, apply rate, and ETA ---
GAP_BYTES=""
GAP_MB=""
GAP_GB=""
CAUGHT_UP=""
APPLY_RATE=""
ETA=""

# Get first and last apply lines to compute rate
FIRST_APPLY_LINE=$(grep "Apply reached" "$LOG" 2>/dev/null | head -1 || true)
FIRST_APPLY_LSN=""
FIRST_APPLY_TS=""
if [ -n "$FIRST_APPLY_LINE" ]; then
    FIRST_APPLY_LSN=$(echo "$FIRST_APPLY_LINE" | grep -oP '\b[0-9A-Fa-f]+/[0-9A-Fa-f]+\b' | head -1 || true)
    FIRST_APPLY_TS=$(echo "$FIRST_APPLY_LINE" | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' || true)
fi

# Use current time as end timestamp — in REPLAY mode, "Apply reached" log lines
# are not emitted, so log timestamps go stale. Current time gives a lifetime
# average rate across both CATCHUP and REPLAY phases.
NOW_EPOCH=$(date +%s 2>/dev/null || true)

if [ -n "$APPLY_LSN" ] && [ -n "$STREAM_LSN" ]; then
    # Parse LSNs: format is HIGH/LOW where each part is hex
    APPLY_HI=$(echo "$APPLY_LSN" | cut -d/ -f1)
    APPLY_LO=$(echo "$APPLY_LSN" | cut -d/ -f2)
    STREAM_HI=$(echo "$STREAM_LSN" | cut -d/ -f1)
    STREAM_LO=$(echo "$STREAM_LSN" | cut -d/ -f2)

    # Convert to full byte position: (high << 32) + low
    APPLY_BYTES=$(( (16#$APPLY_HI * 4294967296) + 16#$APPLY_LO ))
    STREAM_BYTES=$(( (16#$STREAM_HI * 4294967296) + 16#$STREAM_LO ))
    GAP_BYTES=$((STREAM_BYTES - APPLY_BYTES))

    # Clamp to 0 — apply can momentarily be ahead of write_lsn in sentinel
    if [ "$GAP_BYTES" -lt 0 ]; then
        GAP_BYTES=0
    fi

    # For display and rate calc, keep GB with precision
    GAP_MB=$((GAP_BYTES / 1048576))
    GAP_GB=$((GAP_MB / 1024))

    # Determine sync status
    CAUGHT_UP=""
    if [ "$GAP_MB" -le 100 ]; then
        CAUGHT_UP="YES"
    fi

    # Compute apply rate: total bytes applied since first "Apply reached" / elapsed wall time
    if [ -n "$FIRST_APPLY_LSN" ] && [ -n "$FIRST_APPLY_TS" ] && [ -n "$NOW_EPOCH" ]; then
        FIRST_BYTES=$(( (16#$(echo "$FIRST_APPLY_LSN" | cut -d/ -f1) * 4294967296) + 16#$(echo "$FIRST_APPLY_LSN" | cut -d/ -f2) ))
        APPLIED_BYTES=$((APPLY_BYTES - FIRST_BYTES))
        APPLIED_MB=$((APPLIED_BYTES / 1048576))

        # Compute elapsed seconds from first apply log entry to now
        FIRST_EPOCH=$(date -d "$FIRST_APPLY_TS" +%s 2>/dev/null || true)

        if [ -n "$FIRST_EPOCH" ]; then
            ELAPSED_SEC=$((NOW_EPOCH - FIRST_EPOCH))
            if [ "$ELAPSED_SEC" -gt 60 ] && [ "$APPLIED_MB" -gt 0 ]; then
                ELAPSED_HR=$(echo "scale=4; $ELAPSED_SEC / 3600" | bc 2>/dev/null || true)
                if [ -n "$ELAPSED_HR" ] && [ "$ELAPSED_HR" != "0" ]; then
                    # Use MB for precision, convert to GB/hr for display
                    RATE_MB_HR=$(echo "scale=1; $APPLIED_MB / $ELAPSED_HR" | bc 2>/dev/null || true)
                    if [ -n "$RATE_MB_HR" ] && [ "$RATE_MB_HR" != "0" ] && [ "$RATE_MB_HR" != ".0" ]; then
                        RATE_GB_HR=$(echo "scale=1; $RATE_MB_HR / 1024" | bc 2>/dev/null || true)
                        if [ -n "$RATE_GB_HR" ] && [ "$RATE_GB_HR" != "0" ] && [ "$RATE_GB_HR" != ".0" ]; then
                            APPLY_RATE="${RATE_GB_HR} GB/hr"
                        else
                            APPLY_RATE="${RATE_MB_HR} MB/hr"
                        fi
                        if [ "$GAP_GB" -gt 0 ] && [ -n "$RATE_GB_HR" ] && [ "$RATE_GB_HR" != "0" ] && [ "$RATE_GB_HR" != ".0" ]; then
                            ETA_HR=$(echo "scale=1; $GAP_GB / $RATE_GB_HR" | bc 2>/dev/null || true)
                            if [ -n "$ETA_HR" ]; then
                                ETA="${ETA_HR}h"
                            fi
                        elif [ "$GAP_MB" -gt 0 ] && [ -n "$RATE_MB_HR" ] && [ "$RATE_MB_HR" != "0" ]; then
                            ETA_MIN=$(echo "scale=0; $GAP_MB * 60 / $RATE_MB_HR" | bc 2>/dev/null || true)
                            if [ -n "$ETA_MIN" ] && [ "$ETA_MIN" != "0" ]; then
                                ETA="${ETA_MIN}m"
                            else
                                ETA="<1m"
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
fi

# --- 6. Query source replication slot health via psql ---
SLOT_INFO=""
FLUSH_LAG=""
RESTART_LAG=""
WAL_STATUS=""
DB_SIZE=""
CURRENT_WAL_LSN=""
TOTAL_GAP_MB=""
TOTAL_GAP_GB=""

if [ -n "${PGCOPYDB_SOURCE_PGURI:-}" ]; then
    # Get replication slot stats for the pgcopydb slot
    SLOT_INFO=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -F'|' -c "
        SELECT
            slot_name,
            active,
            pg_size_pretty(pg_current_wal_lsn() - confirmed_flush_lsn) AS flush_lag,
            pg_size_pretty(pg_current_wal_lsn() - restart_lsn) AS restart_lag,
            wal_status
        FROM pg_replication_slots
        WHERE slot_name = 'pgcopydb'
        LIMIT 1;
    " 2>/dev/null || true)

    if [ -n "$SLOT_INFO" ]; then
        FLUSH_LAG=$(echo "$SLOT_INFO" | cut -d'|' -f3)
        RESTART_LAG=$(echo "$SLOT_INFO" | cut -d'|' -f4)
        WAL_STATUS=$(echo "$SLOT_INFO" | cut -d'|' -f5)
    fi

    CURRENT_WAL_LSN=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
        "SELECT pg_current_wal_lsn();" 2>/dev/null || true)

    DB_SIZE=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
        "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null || true)

    # Compute total gap: apply LSN → current source WAL (the true end-to-end lag)
    if [ -n "$APPLY_LSN" ] && [ -n "$CURRENT_WAL_LSN" ]; then
        SRC_HI=$(echo "$CURRENT_WAL_LSN" | cut -d/ -f1)
        SRC_LO=$(echo "$CURRENT_WAL_LSN" | cut -d/ -f2)
        SRC_BYTES=$(( (16#$SRC_HI * 4294967296) + 16#$SRC_LO ))
        TOTAL_GAP_BYTES=$((SRC_BYTES - APPLY_BYTES))
        if [ "$TOTAL_GAP_BYTES" -lt 0 ]; then
            TOTAL_GAP_BYTES=0
        fi
        TOTAL_GAP_MB=$((TOTAL_GAP_BYTES / 1048576))
        TOTAL_GAP_GB=$((TOTAL_GAP_MB / 1024))

        # Re-evaluate caught-up status using total gap (apply → source WAL)
        CAUGHT_UP=""
        if [ "$TOTAL_GAP_MB" -le 100 ]; then
            CAUGHT_UP="YES"
        fi
        # Update ETA based on total gap
        if [ -z "$CAUGHT_UP" ] && [ -n "$RATE_MB_HR" ] && [ "$RATE_MB_HR" != "0" ] && [ "$RATE_MB_HR" != ".0" ]; then
            if [ "$TOTAL_GAP_GB" -gt 0 ]; then
                RATE_GB_HR=$(echo "scale=1; $RATE_MB_HR / 1024" | bc 2>/dev/null || true)
                ETA_HR=$(echo "scale=1; $TOTAL_GAP_GB / $RATE_GB_HR" | bc 2>/dev/null || true)
                if [ -n "$ETA_HR" ]; then
                    ETA="${ETA_HR}h"
                fi
            elif [ "$TOTAL_GAP_MB" -gt 0 ]; then
                ETA_MIN=$(echo "scale=0; $TOTAL_GAP_MB * 60 / $RATE_MB_HR" | bc 2>/dev/null || true)
                if [ -n "$ETA_MIN" ] && [ "$ETA_MIN" != "0" ]; then
                    ETA="${ETA_MIN}m"
                else
                    ETA="<1m"
                fi
            fi
        fi
    fi
fi

# --- 7. Get log timestamp for freshness ---
LOG_TS=$(tail -1 "$LOG" 2>/dev/null | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' 2>/dev/null || echo "unknown")

# --- Print Summary ---
NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
echo ""
echo "======================================================================"
echo "  CDC Migration Status -- $NOW"
echo "======================================================================"
echo ""
echo "  Processes:       $PROC_COUNT pgcopydb processes running"
if [ "$PROC_COUNT" -eq 0 ]; then
    echo "                   *** MIGRATION IS NOT RUNNING ***"
fi
echo "  Migration dir:   $MIGRATION_DIR"
echo "  Log:             $(basename "$LOG")"
echo "  Last log entry:  $LOG_TS"
echo ""
echo "  --- Replication Position ---"
if [ -n "$APPLY_LSN" ]; then
    echo "  Apply LSN:       $APPLY_LSN"
    echo "  Apply file:      $APPLY_FILE"
else
    echo "  Apply LSN:       (not found in log)"
fi
if [ -n "$STREAM_LSN" ]; then
    echo "  Streaming LSN:   $STREAM_LSN"
else
    echo "  Streaming LSN:   (not found in log)"
fi
if [ -n "$CAUGHT_UP" ]; then
    if [ -n "$TOTAL_GAP_MB" ]; then
        echo "  *** CDC IS CAUGHT UP (total lag: ${TOTAL_GAP_MB} MB) ***"
    else
        echo "  *** CDC IS CAUGHT UP (apply gap: ${GAP_MB} MB) ***"
    fi
elif [ -n "$TOTAL_GAP_MB" ]; then
    if [ "$TOTAL_GAP_GB" -gt 0 ]; then
        echo "  Total backlog:   ~${TOTAL_GAP_GB} GB (${TOTAL_GAP_MB} MB)"
    else
        echo "  Total backlog:   ${TOTAL_GAP_MB} MB"
    fi
    echo "    Apply → Stream:  ${GAP_MB} MB    Stream → Source: $((TOTAL_GAP_MB - GAP_MB)) MB"
elif [ -n "$GAP_MB" ]; then
    if [ "$GAP_GB" -gt 0 ]; then
        echo "  Apply backlog:   ~${GAP_GB} GB (${GAP_MB} MB)"
    else
        echo "  Apply backlog:   ${GAP_MB} MB"
    fi
fi
if [ -n "$APPLY_RATE" ]; then
    echo "  Apply rate:      ~${APPLY_RATE}"
fi
if [ -n "$ETA" ] && [ -z "$CAUGHT_UP" ]; then
    echo "  Est. time left:  ~${ETA}"
fi
echo ""
echo "  --- Source Health ---"
if [ -n "$FLUSH_LAG" ]; then
    echo "  Flush LSN lag:   $FLUSH_LAG"
    echo "  Restart LSN lag: $RESTART_LAG"
    echo "  WAL status:      $WAL_STATUS"
    [ -n "$CURRENT_WAL_LSN" ] && echo "  Current WAL LSN: $CURRENT_WAL_LSN"
    [ -n "$DB_SIZE" ] && echo "  Database size:   $DB_SIZE"
elif [ -n "${PGCOPYDB_SOURCE_PGURI:-}" ]; then
    echo "  No pgcopydb replication slot found on source"
    [ -n "$CURRENT_WAL_LSN" ] && echo "  Current WAL LSN: $CURRENT_WAL_LSN"
    [ -n "$DB_SIZE" ] && echo "  Database size:   $DB_SIZE"
else
    echo "  (PGCOPYDB_SOURCE_PGURI not set)"
fi
echo ""
echo "  --- Errors ---"
echo "  Error count:     $ERROR_COUNT"
if [ "$ERROR_COUNT" -gt 0 ] && [ -n "$LAST_ERROR" ]; then
    echo "  Last error:      $(echo "$LAST_ERROR" | cut -c1-100)"
fi
echo ""
echo "======================================================================"
echo ""
