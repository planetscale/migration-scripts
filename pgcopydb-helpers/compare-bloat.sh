#!/bin/bash
#
# compare-bloat.sh — Compare database bloat between SOURCE and TARGET
#
# Run on the migration instance where both databases are accessible.
# Reads connection strings from ~/.env (PGCOPYDB_SOURCE_PGURI, PGCOPYDB_TARGET_PGURI)
#
# Compares table heap, TOAST, and index sizes between source and target to
# quantify bloat reduction after migration. Uses only catalog queries —
# no table scans, no writes, no locks, safe for production.
#
# Usage: ./compare-bloat.sh [--min-size-mb N] [--top-indexes N]
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

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# --- Config (overridable via flags) ---
MIN_TABLE_SIZE_MB=100
TOP_INDEX_COUNT=20

while [[ $# -gt 0 ]]; do
    case "$1" in
        --min-size-mb) MIN_TABLE_SIZE_MB="$2"; shift 2 ;;
        --top-indexes) TOP_INDEX_COUNT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

MIN_TABLE_SIZE_BYTES=$((MIN_TABLE_SIZE_MB * 1024 * 1024))

# --- Helper functions ---
src_query() {
    psql "$PGCOPYDB_SOURCE_PGURI" -t -A -F'|' -c "$1" 2>/dev/null || echo ""
}

tgt_query() {
    psql "$PGCOPYDB_TARGET_PGURI" -t -A -F'|' -c "$1" 2>/dev/null || echo ""
}

human_size() {
    local bytes="${1:-0}"
    if [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0 B"
        return
    fi
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes} B"
}

pct() {
    local num="${1:-0}"
    local den="${2:-0}"
    if [ "$den" -eq 0 ] 2>/dev/null; then
        echo "—"
    else
        echo "$((num * 100 / den))%"
    fi
}

# ══════════════════════════════════════════════════════════════════
NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  Database Bloat Comparison — $NOW"
echo "══════════════════════════════════════════════════════════════════"

# --- Section 1: Database Overview ---
echo ""
echo "  DATABASE OVERVIEW"
echo "  ────────────────────────────────────────────────────────────────"

SRC_VER=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c "SHOW server_version;" 2>/dev/null || echo "unknown")
TGT_VER=$(psql "$PGCOPYDB_TARGET_PGURI" -t -A -c "SHOW server_version;" 2>/dev/null || echo "unknown")

SRC_DB_SIZE=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c "SELECT pg_database_size(current_database());" 2>/dev/null || echo "0")
TGT_DB_SIZE=$(psql "$PGCOPYDB_TARGET_PGURI" -t -A -c "SELECT pg_database_size(current_database());" 2>/dev/null || echo "0")

DB_DIFF=$((SRC_DB_SIZE - TGT_DB_SIZE))
DB_PCT=$(pct "$DB_DIFF" "$SRC_DB_SIZE")

echo ""
printf "  %-12s %-20s %s\n" "" "SOURCE" "TARGET"
printf "  %-12s %-20s %s\n" "Version" "PostgreSQL $SRC_VER" "PostgreSQL $TGT_VER"
printf "  %-12s %-20s %s\n" "Total size" "$(human_size "$SRC_DB_SIZE")" "$(human_size "$TGT_DB_SIZE")"
echo ""
echo -e "  ${BOLD}Size reduction: $(human_size "$DB_DIFF") ($DB_PCT)${NC}"

# --- Section 2: Per-Table Comparison ---
echo ""
echo ""
echo "  PER-TABLE COMPARISON (tables > ${MIN_TABLE_SIZE_MB} MB on source)"
echo "  ────────────────────────────────────────────────────────────────"

TABLE_QUERY="
SELECT
    n.nspname || '.' || c.relname,
    pg_relation_size(c.oid, 'main'),
    COALESCE(pg_relation_size(c.reltoastrelid), 0),
    pg_indexes_size(c.oid),
    c.reltuples::bigint
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND pg_relation_size(c.oid, 'main') > ${MIN_TABLE_SIZE_BYTES}
ORDER BY pg_total_relation_size(c.oid) DESC;
"

SRC_TABLES=$(src_query "$TABLE_QUERY")
TGT_TABLES=$(tgt_query "$TABLE_QUERY")

# Parse target into associative arrays
declare -A TGT_HEAP TGT_TOAST TGT_IDX TGT_ROWS
while IFS='|' read -r name heap toast idx rows; do
    [ -z "$name" ] && continue
    TGT_HEAP["$name"]="$heap"
    TGT_TOAST["$name"]="$toast"
    TGT_IDX["$name"]="$idx"
    TGT_ROWS["$name"]="$rows"
done <<< "$TGT_TABLES"

# Accumulators for summary
TOTAL_SRC_HEAP=0
TOTAL_TGT_HEAP=0
TOTAL_SRC_TOAST=0
TOTAL_TGT_TOAST=0
TOTAL_SRC_IDX=0
TOTAL_TGT_IDX=0
TABLE_COUNT=0

echo ""
printf "  ${BOLD}%-40s %10s %10s %6s %10s %10s %6s %10s %10s %6s${NC}\n" \
    "Table" "Src Heap" "Tgt Heap" "Heap%" "Src TOAST" "Tgt TOAST" "TOAST%" "Src Idx" "Tgt Idx" "Idx%"
printf "  %-40s %10s %10s %6s %10s %10s %6s %10s %10s %6s\n" \
    "────────────────────────────────────────" "──────────" "──────────" "──────" "──────────" "──────────" "──────" "──────────" "──────────" "──────"

while IFS='|' read -r name src_heap src_toast src_idx src_rows; do
    [ -z "$name" ] && continue

    tgt_heap="${TGT_HEAP[$name]:-0}"
    tgt_toast="${TGT_TOAST[$name]:-0}"
    tgt_idx="${TGT_IDX[$name]:-0}"

    TOTAL_SRC_HEAP=$((TOTAL_SRC_HEAP + src_heap))
    TOTAL_TGT_HEAP=$((TOTAL_TGT_HEAP + tgt_heap))
    TOTAL_SRC_TOAST=$((TOTAL_SRC_TOAST + src_toast))
    TOTAL_TGT_TOAST=$((TOTAL_TGT_TOAST + tgt_toast))
    TOTAL_SRC_IDX=$((TOTAL_SRC_IDX + src_idx))
    TOTAL_TGT_IDX=$((TOTAL_TGT_IDX + tgt_idx))
    TABLE_COUNT=$((TABLE_COUNT + 1))

    # Truncate long table names
    display_name="$name"
    if [ ${#display_name} -gt 40 ]; then
        display_name="${display_name:0:37}..."
    fi

    heap_diff=$((src_heap - tgt_heap))
    toast_diff=$((src_toast - tgt_toast))
    idx_diff=$((src_idx - tgt_idx))

    printf "  %-40s %10s %10s %6s %10s %10s %6s %10s %10s %6s\n" \
        "$display_name" \
        "$(human_size "$src_heap")" "$(human_size "$tgt_heap")" "$(pct "$heap_diff" "$src_heap")" \
        "$(human_size "$src_toast")" "$(human_size "$tgt_toast")" "$(pct "$toast_diff" "$src_toast")" \
        "$(human_size "$src_idx")" "$(human_size "$tgt_idx")" "$(pct "$idx_diff" "$src_idx")"
done <<< "$SRC_TABLES"

echo ""
HEAP_DIFF_TOTAL=$((TOTAL_SRC_HEAP - TOTAL_TGT_HEAP))
TOAST_DIFF_TOTAL=$((TOTAL_SRC_TOAST - TOTAL_TGT_TOAST))
IDX_DIFF_TOTAL=$((TOTAL_SRC_IDX - TOTAL_TGT_IDX))

printf "  ${BOLD}%-40s %10s %10s %6s %10s %10s %6s %10s %10s %6s${NC}\n" \
    "TOTALS ($TABLE_COUNT tables)" \
    "$(human_size "$TOTAL_SRC_HEAP")" "$(human_size "$TOTAL_TGT_HEAP")" "$(pct "$HEAP_DIFF_TOTAL" "$TOTAL_SRC_HEAP")" \
    "$(human_size "$TOTAL_SRC_TOAST")" "$(human_size "$TOTAL_TGT_TOAST")" "$(pct "$TOAST_DIFF_TOTAL" "$TOTAL_SRC_TOAST")" \
    "$(human_size "$TOTAL_SRC_IDX")" "$(human_size "$TOTAL_TGT_IDX")" "$(pct "$IDX_DIFF_TOTAL" "$TOTAL_SRC_IDX")"

# --- Section 3: Top Indexes by Size Difference ---
echo ""
echo ""
echo "  TOP ${TOP_INDEX_COUNT} INDEXES BY SIZE DIFFERENCE"
echo "  ────────────────────────────────────────────────────────────────"

INDEX_QUERY="
SELECT
    n.nspname || '.' || ci.relname,
    ct.relname,
    pg_relation_size(ci.oid)
FROM pg_class ci
JOIN pg_index i ON i.indexrelid = ci.oid
JOIN pg_class ct ON ct.oid = i.indrelid
JOIN pg_namespace n ON n.oid = ci.relnamespace
WHERE ci.relkind = 'i'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_relation_size(ci.oid) DESC;
"

SRC_INDEXES=$(src_query "$INDEX_QUERY")
TGT_INDEXES=$(tgt_query "$INDEX_QUERY")

# Parse target indexes
declare -A TGT_IDX_SIZE
while IFS='|' read -r idx_name tbl_name idx_size; do
    [ -z "$idx_name" ] && continue
    TGT_IDX_SIZE["$idx_name"]="$idx_size"
done <<< "$TGT_INDEXES"

# Build array of (diff, name, src_size, tgt_size, table) and sort
declare -a IDX_DIFFS=()
while IFS='|' read -r idx_name tbl_name src_size; do
    [ -z "$idx_name" ] && continue
    tgt_size="${TGT_IDX_SIZE[$idx_name]:-0}"
    diff=$((src_size - tgt_size))
    IDX_DIFFS+=("${diff}|${idx_name}|${src_size}|${tgt_size}|${tbl_name}")
done <<< "$SRC_INDEXES"

# Sort by diff descending and take top N
SORTED_IDXS=$(printf '%s\n' "${IDX_DIFFS[@]}" | sort -t'|' -k1 -rn | head -n "$TOP_INDEX_COUNT")

echo ""
printf "  ${BOLD}%-50s %-20s %10s %10s %10s${NC}\n" \
    "Index" "Table" "Source" "Target" "Reduction"
printf "  %-50s %-20s %10s %10s %10s\n" \
    "──────────────────────────────────────────────────" "────────────────────" "──────────" "──────────" "──────────"

while IFS='|' read -r diff idx_name src_size tgt_size tbl_name; do
    [ -z "$idx_name" ] && continue

    display_idx="$idx_name"
    if [ ${#display_idx} -gt 50 ]; then
        display_idx="${display_idx:0:47}..."
    fi
    display_tbl="$tbl_name"
    if [ ${#display_tbl} -gt 20 ]; then
        display_tbl="${display_tbl:0:17}..."
    fi

    printf "  %-50s %-20s %10s %10s %10s\n" \
        "$display_idx" "$display_tbl" \
        "$(human_size "$src_size")" "$(human_size "$tgt_size")" \
        "$(human_size "$diff")"
done <<< "$SORTED_IDXS"

# --- Section 4: Summary ---
HEAP_DIFF=$((TOTAL_SRC_HEAP - TOTAL_TGT_HEAP))
TOAST_DIFF=$((TOTAL_SRC_TOAST - TOTAL_TGT_TOAST))
IDX_DIFF=$((TOTAL_SRC_IDX - TOTAL_TGT_IDX))
TOTAL_DIFF=$((HEAP_DIFF + TOAST_DIFF + IDX_DIFF))
TOTAL_SRC=$((TOTAL_SRC_HEAP + TOTAL_SRC_TOAST + TOTAL_SRC_IDX))

echo ""
echo ""
echo "  ══════════════════════════════════════════════════════════════════"
echo -e "  ${BOLD}BLOAT REDUCTION SUMMARY${NC} (tables > ${MIN_TABLE_SIZE_MB} MB)"
echo "  ══════════════════════════════════════════════════════════════════"
echo ""
printf "  %-20s %12s %12s %12s %8s\n" "Component" "Source" "Target" "Reduction" "Pct"
printf "  %-20s %12s %12s %12s %8s\n" "────────────────────" "────────────" "────────────" "────────────" "────────"
printf "  %-20s %12s %12s %12s %8s\n" \
    "Table heap" "$(human_size "$TOTAL_SRC_HEAP")" "$(human_size "$TOTAL_TGT_HEAP")" "$(human_size "$HEAP_DIFF")" "$(pct "$HEAP_DIFF" "$TOTAL_SRC_HEAP")"
printf "  %-20s %12s %12s %12s %8s\n" \
    "TOAST data" "$(human_size "$TOTAL_SRC_TOAST")" "$(human_size "$TOTAL_TGT_TOAST")" "$(human_size "$TOAST_DIFF")" "$(pct "$TOAST_DIFF" "$TOTAL_SRC_TOAST")"
printf "  %-20s %12s %12s %12s %8s\n" \
    "Indexes" "$(human_size "$TOTAL_SRC_IDX")" "$(human_size "$TOTAL_TGT_IDX")" "$(human_size "$IDX_DIFF")" "$(pct "$IDX_DIFF" "$TOTAL_SRC_IDX")"
printf "  %-20s %12s %12s %12s %8s\n" \
    "────────────────────" "────────────" "────────────" "────────────" "────────"
printf "  ${BOLD}%-20s %12s %12s %12s %8s${NC}\n" \
    "TOTAL" "$(human_size "$TOTAL_SRC")" "$(human_size "$((TOTAL_SRC - TOTAL_DIFF))")" "$(human_size "$TOTAL_DIFF")" "$(pct "$TOTAL_DIFF" "$TOTAL_SRC")"
echo ""
echo "  Database-level: $(human_size "$SRC_DB_SIZE") → $(human_size "$TGT_DB_SIZE") ($(human_size "$DB_DIFF") / $DB_PCT reduction)"
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo ""
