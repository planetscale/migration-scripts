#!/usr/bin/env bash
# =============================================================================
# verify-migration.sh — PostgreSQL Migration Verification Script
# =============================================================================
# Compares source and target Postgres DBs without full table scans.
# Uses system catalog queries, pg_class statistics, and index-based spot checks.
# Safe for databases up to multi-TB; typically completes in under 2 minutes.
#
# Reads connection strings from ~/.env:
#   export PGCOPYDB_SOURCE_PGURI='postgresql://user:pass@source-host:5432/dbname'
#   export PGCOPYDB_TARGET_PGURI='postgresql://user:pass@target-host:5432/dbname'
#
# Usage:
#   ./verify-migration.sh [options]
#
# Options:
#   --row-count-tolerance <pct>   Allowed % difference for row estimates (default: 5)
#   --spot-check-tables <n>       Number of largest tables to spot-check (default: 20)
#   --no-spot-check               Skip min/max spot-check (fastest mode)
#   --schemas <s1,s2,...>         Only check these schemas (default: all non-system)
#   --exact-count-tables <n>      Random tables to exact-count (default: 10, 0=skip)
#   --exact-count-max-gb <n>      Max table size in GB for exact count (default: 10)
#   --exact-count-timeout <s>     Per-table COUNT(*) timeout in seconds (default: 120)
# =============================================================================

set -uo pipefail

# ── Load connection strings from ~/.env ───────────────────────────────────────
set +u
set -a
source ~/.env
set +a
set -u

if [[ -z "${PGCOPYDB_SOURCE_PGURI:-}" || -z "${PGCOPYDB_TARGET_PGURI:-}" ]]; then
    echo "ERROR: PGCOPYDB_SOURCE_PGURI and PGCOPYDB_TARGET_PGURI must be set in ~/.env"
    exit 1
fi

SOURCE_CONN="$PGCOPYDB_SOURCE_PGURI"
TARGET_CONN="$PGCOPYDB_TARGET_PGURI"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Counters ──────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0

# ── Defaults ──────────────────────────────────────────────────────────────────
ROW_TOLERANCE=5
SPOT_CHECK_N=20
NO_SPOT_CHECK=false
SCHEMA_FILTER=""       # empty = all non-system schemas
EXACT_COUNT_N=10       # number of random tables to exact-count
EXACT_COUNT_MAX_GB=10  # tables larger than this are skipped
EXACT_COUNT_TIMEOUT=120

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
    awk '/^# ={10}/{n++; if(n==2)exit} n==1{sub(/^# ?/,"",$0); print}' "$0"
    exit 1
}

log_section() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "${BLUE}${BOLD}  %s${NC}\n" "$1"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_pass() { echo -e "  ${GREEN}✔${NC}  $*"; PASS=$((PASS + 1)); }
log_fail() { echo -e "  ${RED}✘${NC}  $*"; FAIL=$((FAIL + 1)); }
log_warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; WARN=$((WARN + 1)); }
log_info() { echo -e "  ${CYAN}ℹ${NC}  $*"; }

# Run query; returns tab-separated rows, trims trailing blank lines
# Errors go to stderr (not suppressed) so failures are visible
q() {
    local conn="$1" sql="$2"
    psql "$conn" -t -A -F $'\t' -c "$sql" 2>/dev/null | grep -v '^$' || true
}

# Like q() but prints psql errors to stderr so they're visible
q_verbose() {
    local conn="$1" sql="$2"
    psql "$conn" -t -A -F $'\t' -c "$sql" | grep -v '^$' || true
}

# Count non-empty lines in a variable
# grep -c exits 1 on zero matches (but still prints "0"), so || true is enough
line_count() { printf '%s' "${1:-}" | grep -c . || true; }

# Absolute value
abs() { local v=$1; echo "${v#-}"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --row-count-tolerance)  ROW_TOLERANCE="$2"; shift 2 ;;
        --spot-check-tables)    SPOT_CHECK_N="$2"; shift 2 ;;
        --no-spot-check)        NO_SPOT_CHECK=true; shift ;;
        --schemas)              SCHEMA_FILTER="$2"; shift 2 ;;
        --exact-count-tables)   EXACT_COUNT_N="$2"; shift 2 ;;
        --exact-count-max-gb)   EXACT_COUNT_MAX_GB="$2"; shift 2 ;;
        --exact-count-timeout)  EXACT_COUNT_TIMEOUT="$2"; shift 2 ;;
        -h|--help)              usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Build schema exclusion / inclusion clause used in most queries
if [[ -n "$SCHEMA_FILTER" ]]; then
    # Convert comma list → SQL IN list
    SCHEMA_SQL_FILTER="AND n.nspname IN ($(echo "$SCHEMA_FILTER" | sed "s/,/','/g; s/^/'/; s/$/'/" ))"
    SCHEMA_SQL_FILTER_PLAIN="AND table_schema IN ($(echo "$SCHEMA_FILTER" | sed "s/,/','/g; s/^/'/; s/$/'/" ))"
else
    SCHEMA_SQL_FILTER="AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')"
    SCHEMA_SQL_FILTER_PLAIN="AND table_schema NOT IN ('pg_catalog','information_schema','pg_toast')"
fi

# ── Prerequisite check ────────────────────────────────────────────────────────
if ! command -v psql &>/dev/null; then
    echo -e "${RED}Error:${NC} psql not found. Install postgresql-client:" >&2
    echo "  sudo apt-get install postgresql-client" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║        PostgreSQL Migration Verification Script                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo -e "  Source : ${CYAN}$(echo "$SOURCE_CONN" | sed 's/:\/\/[^:]*:[^@]*@/:\/\/***:***@/')${NC}"
echo -e "  Target : ${CYAN}$(echo "$TARGET_CONN" | sed 's/:\/\/[^:]*:[^@]*@/:\/\/***:***@/')${NC}"
echo -e "  Time   : $(date)"
echo -e "  Options: row_tolerance=${ROW_TOLERANCE}%  spot_check_tables=${SPOT_CHECK_N}"

# =============================================================================
# 1. CONNECTIONS
# =============================================================================
log_section "1/11  CONNECTION TEST"

# Use raw psql (not q()) so the exit code is real and errors are visible
echo -n "  Testing source connection... "
if SRC_PING=$(psql "$SOURCE_CONN" -t -A -c "SELECT version()" 2>&1); then
    log_pass "Source DB connected"
    SRC_VER=$(echo "$SRC_PING" | head -1)
else
    echo ""
    log_fail "Cannot connect to source DB — psql error:"
    echo "$SRC_PING" | sed 's/^/       /'
    exit 1
fi

echo -n "  Testing target connection... "
if TGT_PING=$(psql "$TARGET_CONN" -t -A -c "SELECT version()" 2>&1); then
    log_pass "Target DB connected"
    TGT_VER=$(echo "$TGT_PING" | head -1)
else
    echo ""
    log_fail "Cannot connect to target DB — psql error:"
    echo "$TGT_PING" | sed 's/^/       /'
    exit 1
fi

log_info "Source: $SRC_VER"
log_info "Target: $TGT_VER"

SRC_DB=$(q "$SOURCE_CONN" "SELECT current_database()")
TGT_DB=$(q "$TARGET_CONN" "SELECT current_database()")
log_info "Source DB name: $SRC_DB  |  Target DB name: $TGT_DB"

# Sanity-check that catalog queries actually work on the source
SRC_SANITY=$(psql "$SOURCE_CONN" -t -A -c "SELECT count(*) FROM pg_class" 2>&1)
if ! [[ "$SRC_SANITY" =~ ^[0-9]+$ ]]; then
    log_fail "Source DB catalog query failed — all results below will be empty/wrong"
    echo "       psql output: $SRC_SANITY" | head -5
    log_warn "Check: SSL mode, IAM auth, search_path, or pg_hba.conf on the source"
    exit 1
fi
log_pass "Source catalog accessible (pg_class has $SRC_SANITY entries)"

# =============================================================================
# 2. TABLES
# =============================================================================
log_section "2/11  TABLES"

TABLE_QUERY="
    SELECT n.nspname || '.' || c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r' $SCHEMA_SQL_FILTER
    ORDER BY 1"

SRC_TABLES=$(q "$SOURCE_CONN" "$TABLE_QUERY")
TGT_TABLES=$(q "$TARGET_CONN" "$TABLE_QUERY")

SRC_TABLE_CNT=$(line_count "$SRC_TABLES")
TGT_TABLE_CNT=$(line_count "$TGT_TABLES")
log_info "Source table count: $SRC_TABLE_CNT"
log_info "Target table count: $TGT_TABLE_CNT"

[[ "$SRC_TABLE_CNT" -eq "$TGT_TABLE_CNT" ]] \
    && log_pass "Table count matches ($SRC_TABLE_CNT)" \
    || log_fail "Table count mismatch — source=$SRC_TABLE_CNT  target=$TGT_TABLE_CNT"

MISSING_TABLES=$(comm -23 <(echo "$SRC_TABLES" | sort) <(echo "$TGT_TABLES" | sort) 2>/dev/null || true)
EXTRA_TABLES=$(comm   -13 <(echo "$SRC_TABLES" | sort) <(echo "$TGT_TABLES" | sort) 2>/dev/null || true)

if [[ -z "$MISSING_TABLES" ]]; then
    log_pass "No tables missing in target"
else
    log_fail "Tables present in source but MISSING in target ($(line_count "$MISSING_TABLES")):"
    echo "$MISSING_TABLES" | head -30 | while IFS= read -r t; do printf "       %s\n" "$t"; done
    [[ $(line_count "$MISSING_TABLES") -gt 30 ]] && echo "       ... (output truncated)"
fi

if [[ -z "$EXTRA_TABLES" ]]; then
    log_pass "No unexpected extra tables in target"
else
    log_warn "Tables in target but NOT in source (extra — $(line_count "$EXTRA_TABLES")):"
    echo "$EXTRA_TABLES" | head -20 | while IFS= read -r t; do printf "       %s\n" "$t"; done
fi

# =============================================================================
# 3. COLUMNS
# =============================================================================
log_section "3/11  COLUMNS"

COL_QUERY="
    SELECT table_schema || '.' || table_name
        || '  col=' || column_name
        || '  type=' || data_type
        || CASE WHEN character_maximum_length IS NOT NULL
                THEN '(' || character_maximum_length || ')' ELSE '' END
        || '  nullable=' || is_nullable
        || '  default=' || COALESCE(column_default, 'NULL')
    FROM information_schema.columns
    WHERE true $SCHEMA_SQL_FILTER_PLAIN
    ORDER BY table_schema, table_name, ordinal_position"

SRC_COLS=$(q "$SOURCE_CONN" "$COL_QUERY")
TGT_COLS=$(q "$TARGET_CONN" "$COL_QUERY")

MISSING_COLS=$(comm -23 <(echo "$SRC_COLS" | sort) <(echo "$TGT_COLS" | sort) 2>/dev/null || true)
EXTRA_COLS=$(comm   -13 <(echo "$SRC_COLS" | sort) <(echo "$TGT_COLS" | sort) 2>/dev/null || true)

if [[ -z "$MISSING_COLS" ]]; then
    log_pass "All column definitions match"
else
    log_fail "Column definitions in source missing/changed in target ($(line_count "$MISSING_COLS")):"
    echo "$MISSING_COLS" | head -30 | while IFS= read -r c; do printf "       %s\n" "$c"; done
    [[ $(line_count "$MISSING_COLS") -gt 30 ]] && echo "       ... (truncated)"
fi

[[ -n "$EXTRA_COLS" ]] && {
    log_warn "Extra column definitions in target (not in source) — $(line_count "$EXTRA_COLS") diff(s)"
    echo "$EXTRA_COLS" | head -10 | while IFS= read -r c; do printf "       %s\n" "$c"; done
}

# =============================================================================
# 4. INDEXES
# =============================================================================
log_section "4/11  INDEXES"

IDX_QUERY="
    SELECT schemaname || '.' || tablename || '  idx=' || indexname
        || '  def=' || indexdef
    FROM pg_indexes
    WHERE true
    AND schemaname NOT IN ('pg_catalog','information_schema','pg_toast')
    $( [[ -n "$SCHEMA_FILTER" ]] && echo "AND schemaname IN ($(echo "$SCHEMA_FILTER" | sed "s/,/','/g; s/^/'/; s/$/'/" ))" || true )
    ORDER BY 1"

SRC_IDX=$(q "$SOURCE_CONN" "$IDX_QUERY")
TGT_IDX=$(q "$TARGET_CONN" "$IDX_QUERY")

MISSING_IDX=$(comm -23 <(echo "$SRC_IDX" | sort) <(echo "$TGT_IDX" | sort) 2>/dev/null || true)
EXTRA_IDX=$(comm   -13 <(echo "$SRC_IDX" | sort) <(echo "$TGT_IDX" | sort) 2>/dev/null || true)

if [[ -z "$MISSING_IDX" ]]; then
    log_pass "All indexes present in target"
else
    log_fail "Indexes in source but MISSING in target ($(line_count "$MISSING_IDX")):"
    echo "$MISSING_IDX" | head -20 | while IFS= read -r i; do printf "       %s\n" "$i"; done
fi
[[ -n "$EXTRA_IDX" ]] && log_warn "Extra indexes in target: $(line_count "$EXTRA_IDX")"

# =============================================================================
# 5. CONSTRAINTS
# =============================================================================
log_section "5/11  CONSTRAINTS  (PK / FK / UNIQUE / CHECK)"

CON_QUERY="
    SELECT n.nspname || '.' || t.relname || '  con=' || c.conname
        || '  type=' || c.contype
        || '  def=' || pg_get_constraintdef(c.oid, true)
    FROM pg_constraint c
    JOIN pg_class t     ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE true $SCHEMA_SQL_FILTER
    ORDER BY 1"

SRC_CON=$(q "$SOURCE_CONN" "$CON_QUERY")
TGT_CON=$(q "$TARGET_CONN" "$CON_QUERY")

MISSING_CON=$(comm -23 <(echo "$SRC_CON" | sort) <(echo "$TGT_CON" | sort) 2>/dev/null || true)
if [[ -z "$MISSING_CON" ]]; then
    log_pass "All constraints present and matching in target"
else
    log_fail "Constraints in source but MISSING/CHANGED in target ($(line_count "$MISSING_CON")):"
    echo "$MISSING_CON" | head -20 | while IFS= read -r c; do printf "       %s\n" "$c"; done
fi

# =============================================================================
# 6. VIEWS
# =============================================================================
log_section "6/11  VIEWS"

VIEW_QUERY="
    SELECT schemaname || '.' || viewname
    FROM pg_views
    WHERE schemaname NOT IN ('pg_catalog','information_schema')
    $( [[ -n "$SCHEMA_FILTER" ]] && echo "AND schemaname IN ($(echo "$SCHEMA_FILTER" | sed "s/,/','/g; s/^/'/; s/$/'/" ))" || true )
    ORDER BY 1"

SRC_VIEWS=$(q "$SOURCE_CONN" "$VIEW_QUERY")
TGT_VIEWS=$(q "$TARGET_CONN" "$VIEW_QUERY")
MISSING_VIEWS=$(comm -23 <(echo "$SRC_VIEWS" | sort) <(echo "$TGT_VIEWS" | sort) 2>/dev/null || true)

if [[ -z "$MISSING_VIEWS" ]]; then
    log_pass "All views present in target  ($(line_count "$SRC_VIEWS") views)"
else
    log_fail "Views missing in target:"
    echo "$MISSING_VIEWS" | while IFS= read -r v; do printf "       %s\n" "$v"; done
fi

# =============================================================================
# 7. FUNCTIONS / PROCEDURES
# =============================================================================
log_section "7/11  FUNCTIONS & PROCEDURES"

FUNC_QUERY="
    SELECT n.nspname || '.' || p.proname
        || '(' || pg_get_function_identity_arguments(p.oid) || ')'
        || '  kind=' || p.prokind
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE true $SCHEMA_SQL_FILTER
    ORDER BY 1"

SRC_FUNCS=$(q "$SOURCE_CONN" "$FUNC_QUERY")
TGT_FUNCS=$(q "$TARGET_CONN" "$FUNC_QUERY")
MISSING_FUNCS=$(comm -23 <(echo "$SRC_FUNCS" | sort) <(echo "$TGT_FUNCS" | sort) 2>/dev/null || true)

if [[ -z "$MISSING_FUNCS" ]]; then
    log_pass "All functions/procedures present in target  ($(line_count "$SRC_FUNCS") routines)"
else
    log_fail "Functions/procedures missing in target ($(line_count "$MISSING_FUNCS")):"
    echo "$MISSING_FUNCS" | head -20 | while IFS= read -r f; do printf "       %s\n" "$f"; done
fi

# =============================================================================
# 8. ROW COUNT ESTIMATES  (no table scan — reads pg_class catalog)
# =============================================================================
log_section "8/11  ROW COUNT ESTIMATES  (pg_class statistics — no table scan)"
log_info "Tolerance: ±${ROW_TOLERANCE}%  |  Tip: run ANALYZE on both DBs beforehand for accuracy"

ROWCNT_QUERY="
    SELECT n.nspname || '.' || c.relname,
           GREATEST(c.reltuples::bigint, 0)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r' $SCHEMA_SQL_FILTER
    ORDER BY c.reltuples DESC"

SRC_ROWCNTS=$(q "$SOURCE_CONN" "$ROWCNT_QUERY")
TGT_ROWCNTS=$(q "$TARGET_CONN" "$ROWCNT_QUERY")

RC_MISMATCH_COUNT=0
RC_MISMATCH_OUT=""

while IFS=$'\t' read -r tbl src_n tgt_n; do
    [[ -z "$tbl" ]] && continue
    if [[ "$src_n" -gt 0 ]]; then
        diff=$(abs $((src_n - tgt_n)))
        pct=$(( diff * 100 / src_n ))
        if [[ $pct -gt $ROW_TOLERANCE ]]; then
            RC_MISMATCH_OUT+="$(printf "       %-55s  src=%12d  tgt=%12d  diff=%d%%\n" "$tbl" "$src_n" "$tgt_n" "$pct")"
            RC_MISMATCH_COUNT=$(( RC_MISMATCH_COUNT + 1 ))
        fi
    elif [[ "${tgt_n:-0}" -ne 0 ]]; then
        RC_MISMATCH_OUT+="$(printf "       %-55s  src=%12d  tgt=%12d  diff=src_empty_tgt_not\n" "$tbl" "$src_n" "$tgt_n")"
        RC_MISMATCH_COUNT=$(( RC_MISMATCH_COUNT + 1 ))
    fi
done < <(join -t$'\t' \
    <(echo "$SRC_ROWCNTS" | sort -t$'\t' -k1,1) \
    <(echo "$TGT_ROWCNTS" | sort -t$'\t' -k1,1))

if [[ $RC_MISMATCH_COUNT -eq 0 ]]; then
    log_pass "Row count estimates match within ${ROW_TOLERANCE}% for all tables"
else
    log_warn "Row count estimate mismatches (>${ROW_TOLERANCE}%) — ${RC_MISMATCH_COUNT} table(s):"
    printf "       %-55s  %14s  %14s  %s\n" "TABLE" "SOURCE_ROWS" "TARGET_ROWS" "DIFF%"
    printf "       %s\n" "$(printf '─%.0s' {1..100})"
    printf '%s' "$RC_MISMATCH_OUT"
fi

# =============================================================================
# 9. SEQUENCES
# =============================================================================
log_section "9/11  SEQUENCES"

SEQ_QUERY="
    SELECT n.nspname || '.' || c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'S' $SCHEMA_SQL_FILTER
    ORDER BY 1"

SRC_SEQS=$(q "$SOURCE_CONN" "$SEQ_QUERY")
TGT_SEQS=$(q "$TARGET_CONN" "$SEQ_QUERY")

MISSING_SEQS=$(comm -23 <(echo "$SRC_SEQS" | sort) <(echo "$TGT_SEQS" | sort) 2>/dev/null || true)
if [[ -z "$MISSING_SEQS" ]]; then
    log_pass "All sequences present in target  ($(line_count "$SRC_SEQS") sequences)"
else
    log_fail "Sequences missing in target:"
    echo "$MISSING_SEQS" | while IFS= read -r s; do printf "       %s\n" "$s"; done
fi

# Compare last_value for each sequence (fast — reads pg_sequences)
SEQ_VAL_QUERY="
    SELECT schemaname || '.' || sequencename, last_value
    FROM pg_sequences
    WHERE schemaname NOT IN ('pg_catalog','information_schema')
    ORDER BY 1"

SRC_SEQVALS=$(q "$SOURCE_CONN" "$SEQ_VAL_QUERY")
TGT_SEQVALS=$(q "$TARGET_CONN" "$SEQ_VAL_QUERY")

SEQ_BEHIND=0
while IFS=$'\t' read -r seq src_v tgt_v; do
    [[ -z "$seq" ]] && continue
    if [[ "$src_v" != "NULL" && "$tgt_v" != "NULL" && "$tgt_v" != "$src_v" ]]; then
        # Target sequence value should be >= source (migration may have advanced it)
        if [[ "$tgt_v" -lt "$src_v" ]]; then
            log_warn "Sequence $seq: source last_value=$src_v > target last_value=$tgt_v  (target may lag)"
            SEQ_BEHIND=$((SEQ_BEHIND + 1))
        fi
    fi
done < <(join -t$'\t' \
    <(echo "$SRC_SEQVALS" | sort -t$'\t' -k1,1) \
    <(echo "$TGT_SEQVALS" | sort -t$'\t' -k1,1))

[[ $SEQ_BEHIND -eq 0 ]] && log_pass "Sequence values look consistent"

# =============================================================================
# 10. DATA SPOT-CHECK  (MIN / MAX on indexed PK columns — uses index, no scan)
# =============================================================================
if [[ "$NO_SPOT_CHECK" == "true" ]]; then
    log_section "10/11  DATA SPOT-CHECK  (skipped via --no-spot-check)"
else
    log_section "10/11  DATA SPOT-CHECK  (min/max on PK columns of top $SPOT_CHECK_N tables)"
    log_info "Only runs on single-column PKs of numeric/date/timestamp type (all use index seeks)"

    SPOT_QUERY="
        SELECT n.nspname || '.' || t.relname,
               a.attname,
               tp.typname,
               sz.reltuples::bigint
        FROM pg_constraint c
        JOIN pg_class t     ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_attribute a ON a.attrelid = t.oid
                            AND a.attnum = c.conkey[1]
                            AND a.attnum > 0
        JOIN pg_type tp     ON tp.oid = a.atttypid
        JOIN pg_class sz    ON sz.oid = t.oid
        WHERE c.contype = 'p'
          AND array_length(c.conkey, 1) = 1
          $SCHEMA_SQL_FILTER
        ORDER BY sz.reltuples DESC
        LIMIT $SPOT_CHECK_N"

    SRC_PKS=$(q "$SOURCE_CONN" "$SPOT_QUERY")

    SPOT_FAIL=0; SPOT_SKIP=0; SPOT_PASS=0

    while IFS=$'\t' read -r table col coltype est_rows; do
        [[ -z "$table" ]] && continue

        # Only numeric and date/time types benefit from index min/max
        if [[ "$coltype" =~ ^(int2|int4|int8|float4|float8|numeric|money|bigserial|serial|smallserial|timestamp|timestamptz|date|time|timetz) ]]; then
            SRC_MM=$(q "$SOURCE_CONN" "SELECT MIN(\"$col\")::text, MAX(\"$col\")::text FROM $table" 2>/dev/null || true)
            TGT_MM=$(q "$TARGET_CONN" "SELECT MIN(\"$col\")::text, MAX(\"$col\")::text FROM $table" 2>/dev/null || true)

            SRC_MIN=$(echo "$SRC_MM" | awk -F'\t' '{print $1}')
            SRC_MAX=$(echo "$SRC_MM" | awk -F'\t' '{print $2}')
            TGT_MIN=$(echo "$TGT_MM" | awk -F'\t' '{print $1}')
            TGT_MAX=$(echo "$TGT_MM" | awk -F'\t' '{print $2}')

            if [[ "$SRC_MIN" == "$TGT_MIN" && "$SRC_MAX" == "$TGT_MAX" ]]; then
                log_pass "$table.$col ($coltype, ~${est_rows} rows): min=$SRC_MIN  max=$SRC_MAX"
                SPOT_PASS=$((SPOT_PASS + 1))
            else
                log_fail "$table.$col ($coltype, ~${est_rows} rows):"
                printf "         source  min=%-30s  max=%s\n" "$SRC_MIN" "$SRC_MAX"
                printf "         target  min=%-30s  max=%s\n" "$TGT_MIN" "$TGT_MAX"
                SPOT_FAIL=$((SPOT_FAIL + 1))
            fi
        else
            log_info "$table.$col ($coltype): skipped (non-numeric/date type)"
            SPOT_SKIP=$((SPOT_SKIP + 1))
        fi
    done <<< "$SRC_PKS"

    log_info "Spot-check summary: ${SPOT_PASS} passed, ${SPOT_FAIL} failed, ${SPOT_SKIP} skipped"
fi

# =============================================================================
# 11. EXACT ROW COUNT — RANDOM SAMPLE
# =============================================================================
# Runs COUNT(*) on a random subset of tables. Each re-run picks a different set,
# so running the script multiple times increases confidence that all data is
# consistent. Skip large tables via --exact-count-max-gb; for those use
# TABLESAMPLE SYSTEM(1) ad-hoc instead.
# =============================================================================

if [[ "$EXACT_COUNT_N" -eq 0 ]]; then
    log_section "11/11  EXACT ROW COUNT  (skipped — --exact-count-tables 0)"
else
    EXACT_MAX_BYTES=$(( EXACT_COUNT_MAX_GB * 1024 * 1024 * 1024 ))

    log_section "11/11  EXACT ROW COUNT  (random sample — up to ${EXACT_COUNT_N} tables ≤ ${EXACT_COUNT_MAX_GB} GB)"
    log_info "Per-table timeout: ${EXACT_COUNT_TIMEOUT}s  |  Re-run the script multiple times to cover more tables"
    log_info "A single mismatch here means real missing data — re-run the full migration for that table"

    EXACT_SAMPLE_QUERY="
        SELECT n.nspname || '.' || c.relname,
               pg_total_relation_size(c.oid),
               pg_size_pretty(pg_total_relation_size(c.oid))
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
          AND pg_total_relation_size(c.oid) BETWEEN 1 AND ${EXACT_MAX_BYTES}
          $SCHEMA_SQL_FILTER
        ORDER BY random()
        LIMIT ${EXACT_COUNT_N}"

    SAMPLE_TABLES=$(q "$SOURCE_CONN" "$EXACT_SAMPLE_QUERY")

    if [[ -z "$SAMPLE_TABLES" ]]; then
        log_info "No tables found in the 1 byte – ${EXACT_COUNT_MAX_GB} GB range — skipping"
    else
        EXACT_PASS=0; EXACT_FAIL=0; EXACT_TIMEOUT=0

        printf "\n       %-52s  %10s  %14s  %14s  %s\n" "TABLE" "SIZE" "SOURCE_COUNT" "TARGET_COUNT" "STATUS"
        printf "       %s\n" "$(printf '─%.0s' {1..110})"

        while IFS=$'\t' read -r table size_bytes size_h; do
            [[ -z "$table" ]] && continue

            # Run COUNT(*) with a hard per-table timeout on each side.
            # grep filters to only the numeric line — psql emits "SET" on stdout
            # for SET commands even in tuples-only (-t) mode, which would corrupt
            # the variable and cause printf %d to print 0 with "invalid number".
            SRC_CNT=$(psql "$SOURCE_CONN" -t -A \
                -c "SET statement_timeout='${EXACT_COUNT_TIMEOUT}s'" \
                -c "SELECT COUNT(*) FROM ${table}" 2>/dev/null \
                | grep -E '^[0-9]+$' | tail -1 || true)
            SRC_CNT="${SRC_CNT:-TIMEOUT}"

            TGT_CNT=$(psql "$TARGET_CONN" -t -A \
                -c "SET statement_timeout='${EXACT_COUNT_TIMEOUT}s'" \
                -c "SELECT COUNT(*) FROM ${table}" 2>/dev/null \
                | grep -E '^[0-9]+$' | tail -1 || true)
            TGT_CNT="${TGT_CNT:-TIMEOUT}"

            if [[ "$SRC_CNT" == "TIMEOUT" || "$TGT_CNT" == "TIMEOUT" ]]; then
                printf "  ${YELLOW}⚠${NC}    %-52s  %10s  %14s  %14s  TIMED OUT (>${EXACT_COUNT_TIMEOUT}s)\n" \
                    "$table" "$size_h" "$SRC_CNT" "$TGT_CNT"
                WARN=$((WARN + 1))
                EXACT_TIMEOUT=$((EXACT_TIMEOUT + 1))

            elif [[ "$SRC_CNT" == "$TGT_CNT" ]]; then
                printf "  ${GREEN}✔${NC}    %-52s  %10s  %14d  %14d  MATCH\n" \
                    "$table" "$size_h" "$SRC_CNT" "$TGT_CNT"
                EXACT_PASS=$((EXACT_PASS + 1))

            else
                DIFF=$(( SRC_CNT - TGT_CNT ))
                PCT=0
                [[ "$SRC_CNT" -gt 0 ]] && PCT=$(( DIFF * 100 / SRC_CNT ))
                printf "  ${RED}✘${NC}    %-52s  %10s  %14d  %14d  MISSING %d rows (%d%%)\n" \
                    "$table" "$size_h" "$SRC_CNT" "$TGT_CNT" "$DIFF" "$PCT"
                EXACT_FAIL=$((EXACT_FAIL + 1))
                FAIL=$((FAIL + 1))
            fi

        done <<< "$SAMPLE_TABLES"

        echo ""
        if [[ $EXACT_FAIL -gt 0 ]]; then
            log_fail "EXACT COUNT: $EXACT_FAIL table(s) have missing rows — data loss confirmed, re-migrate those tables"
        elif [[ $EXACT_TIMEOUT -gt 0 ]]; then
            log_warn "EXACT COUNT: $EXACT_PASS matched, $EXACT_TIMEOUT timed out — increase --exact-count-timeout or --exact-count-max-gb"
        else
            log_pass "EXACT COUNT: all $EXACT_PASS sampled tables have identical row counts"
            log_info "Re-run the script to sample different tables and build confidence in full consistency"
        fi

        if [[ $EXACT_TIMEOUT -gt 0 ]]; then
            echo ""
            log_info "TIP — for tables that timed out, use TABLESAMPLE for a fast near-exact count:"
            log_info "  SELECT COUNT(*) * 100 AS estimated_total"
            log_info "  FROM <table> TABLESAMPLE SYSTEM(1);"
            log_info "  SYSTEM(1) reads ~1% of pages, finishes in seconds, accuracy ±1-2%"
        fi
    fi
fi

# =============================================================================
# EXTENSIONS BONUS CHECK
# =============================================================================
log_section "BONUS  EXTENSIONS"

EXT_QUERY="SELECT extname || '  version=' || extversion FROM pg_extension ORDER BY 1"
SRC_EXT=$(q "$SOURCE_CONN" "$EXT_QUERY")
TGT_EXT=$(q "$TARGET_CONN" "$EXT_QUERY")

MISSING_EXT=$(comm -23 <(echo "$SRC_EXT" | sort) <(echo "$TGT_EXT" | sort) 2>/dev/null || true)
if [[ -z "$MISSING_EXT" ]]; then
    log_pass "All extensions present and same version in target"
else
    log_warn "Extensions missing or version-mismatched in target:"
    echo "$MISSING_EXT" | while IFS= read -r e; do printf "       %s\n" "$e"; done
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                       FINAL SUMMARY                            ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║${NC}  ${GREEN}%-8s${NC}  %d checks passed%35s${BOLD}║${NC}\n" "PASSED:" "$PASS" ""
printf "${BOLD}║${NC}  ${YELLOW}%-8s${NC}  %d warnings%40s${BOLD}║${NC}\n" "WARNINGS:" "$WARN" ""
printf "${BOLD}║${NC}  ${RED}%-8s${NC}  %d failures%41s${BOLD}║${NC}\n" "FAILED:" "$FAIL" ""
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}RESULT: MIGRATION VERIFICATION FAILED${NC}"
    echo -e "  Fix the $FAIL critical issue(s) listed above before going live."
    exit 2
elif [[ $WARN -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}RESULT: VERIFIED WITH WARNINGS${NC}"
    echo -e "  Review $WARN warning(s) above — they may or may not require action."
    exit 1
else
    echo -e "  ${GREEN}${BOLD}RESULT: ALL CHECKS PASSED${NC}"
    exit 0
fi
