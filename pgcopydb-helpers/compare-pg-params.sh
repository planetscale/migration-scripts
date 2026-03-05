#!/bin/bash
#
# compare-pg-params.sh — Compare PostgreSQL parameters between SOURCE and TARGET
#
# Run on the migration instance where both databases are accessible.
# Reads connection strings from ~/.env (PGCOPYDB_SOURCE_PGURI, PGCOPYDB_TARGET_PGURI)
#
# Output: side-by-side comparison of all performance-relevant parameters,
# flagging differences and whether changes require a restart.
#
set -euo pipefail

# --- Load environment ---
set +u
set -a
source ~/.env
set +a
set -u

if [ -z "${PGCOPYDB_SOURCE_PGURI:-}" ] || [ -z "${PGCOPYDB_TARGET_PGURI:-}" ]; then
    echo "ERROR: PGCOPYDB_SOURCE_PGURI and PGCOPYDB_TARGET_PGURI must be set in ~/.env"
    exit 1
fi
# --- loaded ---

# --- Parameters to compare ---
# All PlanetScale-exposed parameters plus additional performance-relevant ones.
# Format: parameter_name|restart_required|category
PARAMS=(
    # Resource Usage
    "effective_io_concurrency|no|Resource Usage"
    "effective_cache_size|no|Resource Usage"
    "huge_pages|YES|Resource Usage"
    "maintenance_io_concurrency|no|Resource Usage"
    "maintenance_work_mem|no|Resource Usage"
    "max_parallel_maintenance_workers|no|Resource Usage"
    "max_parallel_workers|no|Resource Usage"
    "max_parallel_workers_per_gather|no|Resource Usage"
    "max_worker_processes|YES|Resource Usage"
    "shared_buffers|YES|Resource Usage"
    "work_mem|no|Resource Usage"

    # Query Tuning
    "deadlock_timeout|no|Query Tuning"
    "default_statistics_target|no|Query Tuning"
    "random_page_cost|no|Query Tuning"
    "seq_page_cost|no|Query Tuning"
    "cpu_tuple_cost|n/a|Query Tuning"
    "cpu_index_tuple_cost|n/a|Query Tuning"
    "cpu_operator_cost|n/a|Query Tuning"
    "enable_hashjoin|n/a|Query Tuning"
    "enable_mergejoin|n/a|Query Tuning"
    "enable_nestloop|n/a|Query Tuning"
    "enable_seqscan|n/a|Query Tuning"
    "enable_indexscan|n/a|Query Tuning"
    "enable_indexonlyscan|n/a|Query Tuning"
    "enable_bitmapscan|n/a|Query Tuning"
    "enable_partitionwise_join|n/a|Query Tuning"
    "enable_partitionwise_aggregate|n/a|Query Tuning"
    "from_collapse_limit|n/a|Query Tuning"
    "join_collapse_limit|n/a|Query Tuning"
    "jit|n/a|Query Tuning"
    "jit_above_cost|n/a|Query Tuning"
    "jit_inline_above_cost|n/a|Query Tuning"
    "jit_optimize_above_cost|n/a|Query Tuning"

    # WAL
    "max_slot_wal_keep_size|no|WAL"
    "max_wal_size|no|WAL"
    "min_wal_size|no|WAL"
    "wal_buffers|YES|WAL"
    "wal_level|YES|WAL"
    "checkpoint_completion_target|n/a|WAL"
    "checkpoint_timeout|n/a|WAL"

    # Connections
    "max_connections|YES|Connections"

    # Replication
    "hot_standby_feedback|no|Replication"
    "max_logical_replication_workers|YES|Replication"
    "max_replication_slots|YES|Replication"
    "max_sync_workers_per_subscription|no|Replication"
    "max_wal_senders|YES|Replication"

    # Autovacuum
    "autovacuum_vacuum_scale_factor|no|Autovacuum"
    "autovacuum_analyze_scale_factor|no|Autovacuum"
    "autovacuum_max_workers|n/a|Autovacuum"
    "autovacuum_naptime|n/a|Autovacuum"
    "autovacuum_vacuum_cost_delay|n/a|Autovacuum"
    "autovacuum_vacuum_cost_limit|n/a|Autovacuum"

    # Statistics / Logging
    "track_io_timing|no|Statistics"
    "log_lock_waits|no|Logging"
    "log_min_duration_statement|no|Logging"

    # Other
    "shared_preload_libraries|YES|Libraries"
    "temp_buffers|n/a|Memory"
    "hash_mem_multiplier|n/a|Memory"
)

# --- Build SQL to fetch all parameters in one query ---
build_query() {
    local param_names=""
    for entry in "${PARAMS[@]}"; do
        local name="${entry%%|*}"
        if [ -n "$param_names" ]; then
            param_names="$param_names, '$name'"
        else
            param_names="'$name'"
        fi
    done
    echo "SELECT name, setting, unit, CASE WHEN unit IS NOT NULL THEN setting || ' ' || unit ELSE setting END AS display FROM pg_settings WHERE name IN ($param_names) ORDER BY name;"
}

QUERY=$(build_query)

# --- Fetch from both ---
echo "Fetching parameters from SOURCE..." >&2
SRC_DATA=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -F'|' -c "$QUERY" 2>/dev/null) || {
    echo "ERROR: Failed to connect to SOURCE" >&2
    exit 1
}

echo "Fetching parameters from TARGET..." >&2
TGT_DATA=$(psql "$PGCOPYDB_TARGET_PGURI" -t -A -F'|' -c "$QUERY" 2>/dev/null) || {
    echo "ERROR: Failed to connect to TARGET" >&2
    exit 1
}

# --- Get versions ---
SRC_VER=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c "SHOW server_version;" 2>/dev/null || echo "unknown")
TGT_VER=$(psql "$PGCOPYDB_TARGET_PGURI" -t -A -c "SHOW server_version;" 2>/dev/null || echo "unknown")

# --- Parse into associative arrays ---
declare -A SRC_VALS TGT_VALS

while IFS='|' read -r name setting unit display; do
    [ -z "$name" ] && continue
    SRC_VALS["$name"]="$display"
done <<< "$SRC_DATA"

while IFS='|' read -r name setting unit display; do
    [ -z "$name" ] && continue
    TGT_VALS["$name"]="$display"
done <<< "$TGT_DATA"

# --- Print report ---
NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

echo ""
echo "=============================================================================="
echo "  PostgreSQL Parameter Comparison — $NOW"
echo "=============================================================================="
echo ""
echo "  SOURCE: PostgreSQL $SRC_VER"
echo "  TARGET: PostgreSQL $TGT_VER"
echo ""
echo "  Legend: [DIFF] = values differ   [SAME] = values match"
echo "          Restart: YES = requires cluster restart, no = reload only"
echo ""

CURRENT_CAT=""
DIFF_COUNT=0
SAME_COUNT=0

for entry in "${PARAMS[@]}"; do
    IFS='|' read -r name restart category <<< "$entry"

    # Print category header
    if [ "$category" != "$CURRENT_CAT" ]; then
        echo ""
        echo "  --- $category ---"
        printf "  %-40s %-25s %-25s %-8s %s\n" "Parameter" "SOURCE" "TARGET" "Restart" "Status"
        printf "  %-40s %-25s %-25s %-8s %s\n" "----------------------------------------" "-------------------------" "-------------------------" "--------" "------"
        CURRENT_CAT="$category"
    fi

    src_val="${SRC_VALS[$name]:-N/A}"
    tgt_val="${TGT_VALS[$name]:-N/A}"

    if [ "$src_val" = "$tgt_val" ]; then
        status="[SAME]"
        SAME_COUNT=$((SAME_COUNT + 1))
    else
        status="[DIFF] ◄"
        DIFF_COUNT=$((DIFF_COUNT + 1))
    fi

    printf "  %-40s %-25s %-25s %-8s %s\n" "$name" "$src_val" "$tgt_val" "$restart" "$status"
done

echo ""
echo "=============================================================================="
echo "  Summary: $DIFF_COUNT differences, $SAME_COUNT matching"
echo "=============================================================================="
echo ""
