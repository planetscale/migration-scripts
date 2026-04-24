#!/bin/bash
#
# preflight-check.sh — Validate migration prerequisites before starting pgcopydb
#
# Run on the migration instance where both databases are accessible.
# Reads connection strings from ~/.env (PGCOPYDB_SOURCE_PGURI, PGCOPYDB_TARGET_PGURI)
#
# Checks source, target, and local instance for common issues that cause
# mid-migration failures: wrong wal_level, missing replication permissions,
# full replication slots, conflicting publications, leftover state, etc.
#
# Read-only — makes no modifications to either database.
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
NC='\033[0m'

# --- Counters ---
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
    local label="$1"
    local detail="$2"
    printf "  ${GREEN}[PASS]${NC} %-28s %s\n" "$label" "$detail"
    PASS_COUNT=$((PASS_COUNT + 1))
}

warn() {
    local label="$1"
    local detail="$2"
    printf "  ${YELLOW}[WARN]${NC} %-28s %s\n" "$label" "$detail"
    WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
    local label="$1"
    local detail="$2"
    printf "  ${RED}[FAIL]${NC} %-28s %s\n" "$label" "$detail"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# --- Helper: run a query, return empty string on failure ---
src_query() {
    psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c "$1" 2>/dev/null || echo ""
}

tgt_query() {
    psql "$PGCOPYDB_TARGET_PGURI" -t -A -c "$1" 2>/dev/null || echo ""
}

# ══════════════════════════════════════════════════════════════════
NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  pgcopydb Migration Preflight Check — $NOW"
echo "══════════════════════════════════════════════════════════════════"

# ── SOURCE DATABASE ────────────────────────────────────────────────
echo ""
echo "  SOURCE DATABASE"
echo "  ────────────────────────────────────────────────────────────────"

# 1. Connectivity
SRC_VER=$(src_query "SHOW server_version;")
if [ -n "$SRC_VER" ]; then
    pass "Connectivity" "PostgreSQL $SRC_VER"
else
    fail "Connectivity" "cannot connect to source"
    # Skip remaining source checks
    echo ""
    echo "  TARGET DATABASE"
    echo "  ────────────────────────────────────────────────────────────────"
    echo "  (skipping — source connection failed)"
    echo ""
    echo "══════════════════════════════════════════════════════════════════"
    echo "  Summary: $PASS_COUNT passed, $WARN_COUNT warnings, $FAIL_COUNT failed"
    echo "══════════════════════════════════════════════════════════════════"
    echo ""
    exit 1
fi

# 2. WAL level
WAL_LEVEL=$(src_query "SHOW wal_level;")
if [ "$WAL_LEVEL" = "logical" ]; then
    pass "WAL level" "logical"
else
    fail "WAL level" "$WAL_LEVEL (must be logical for CDC)"
fi

# 3. Replication permission
REPL_INFO=$(src_query "SELECT rolreplication, rolsuper FROM pg_roles WHERE rolname = current_user;")
ROL_REPL=$(echo "$REPL_INFO" | cut -d'|' -f1)
ROL_SUPER=$(echo "$REPL_INFO" | cut -d'|' -f2)

# Check RDS-specific replication role
RDS_REPL=$(src_query "SELECT pg_has_role(current_user, 'rds_replication', 'member');" 2>/dev/null || echo "")

if [ "$ROL_REPL" = "t" ]; then
    pass "Replication permission" "role has REPLICATION attribute"
elif [ "$ROL_SUPER" = "t" ]; then
    pass "Replication permission" "role has SUPERUSER attribute"
elif [ "$RDS_REPL" = "t" ]; then
    pass "Replication permission" "role is member of rds_replication"
else
    fail "Replication permission" "no REPLICATION, SUPERUSER, or rds_replication"
fi

# 4. Replication slots
SLOT_INFO=$(src_query "SELECT count(*), current_setting('max_replication_slots')::int FROM pg_replication_slots;")
SLOTS_USED=$(echo "$SLOT_INFO" | cut -d'|' -f1)
SLOTS_MAX=$(echo "$SLOT_INFO" | cut -d'|' -f2)
SLOTS_AVAIL=$((SLOTS_MAX - SLOTS_USED))
if [ "$SLOTS_AVAIL" -gt 0 ]; then
    pass "Replication slots" "$SLOTS_USED of $SLOTS_MAX in use ($SLOTS_AVAIL available)"
else
    fail "Replication slots" "$SLOTS_USED of $SLOTS_MAX in use (none available)"
fi

# 5. WAL senders
SENDER_INFO=$(src_query "SELECT count(*), current_setting('max_wal_senders')::int FROM pg_stat_replication;")
SENDERS_USED=$(echo "$SENDER_INFO" | cut -d'|' -f1)
SENDERS_MAX=$(echo "$SENDER_INFO" | cut -d'|' -f2)
SENDERS_AVAIL=$((SENDERS_MAX - SENDERS_USED))
if [ "$SENDERS_AVAIL" -gt 0 ]; then
    pass "WAL senders" "$SENDERS_USED of $SENDERS_MAX in use ($SENDERS_AVAIL available)"
else
    fail "WAL senders" "$SENDERS_USED of $SENDERS_MAX in use (none available)"
fi

# 6. Existing pgcopydb slot
PGCOPYDB_SLOT=$(src_query "SELECT slot_name FROM pg_replication_slots WHERE slot_name = 'pgcopydb';")
if [ -n "$PGCOPYDB_SLOT" ]; then
    warn "Existing pgcopydb slot" "slot \"pgcopydb\" exists (leftover?)"
else
    pass "Existing pgcopydb slot" "none"
fi

# 7. Publications with puballtables
PUB_ALL=$(src_query "SELECT pubname FROM pg_publication WHERE puballtables = true;")
if [ -n "$PUB_ALL" ]; then
    PUB_NAMES=$(echo "$PUB_ALL" | tr '\n' ', ' | sed 's/,$//')
    warn "Publications" "\"$PUB_NAMES\" is FOR ALL TABLES — use --skip-publications"
else
    pass "Publications" "no FOR ALL TABLES publications"
fi

# 8. wal_sender_timeout
WAL_TIMEOUT=$(src_query "SHOW wal_sender_timeout;")
if [ "$WAL_TIMEOUT" = "0" ] || [ "$WAL_TIMEOUT" = "0s" ] || [ "$WAL_TIMEOUT" = "0ms" ]; then
    pass "wal_sender_timeout" "0 (disabled)"
else
    warn "wal_sender_timeout" "$WAL_TIMEOUT (recommend 0 for large migrations)"
fi

# 9. Prepared transactions
PREP_COUNT=$(src_query "SELECT count(*) FROM pg_prepared_xacts;")
if [ "${PREP_COUNT:-0}" = "0" ]; then
    pass "Prepared transactions" "none"
else
    warn "Prepared transactions" "$PREP_COUNT found (can block slot creation)"
fi

# 10. Source user read permissions
# CONNECT on the database (already connected, but explicit grant is required)
DB_CONNECT=$(src_query "SELECT has_database_privilege(current_user, current_database(), 'CONNECT');")
SRC_USER=$(src_query "SELECT current_user;")
if [ "$DB_CONNECT" = "t" ]; then
    pass "DB connect privilege" "$SRC_USER"
else
    fail "DB connect privilege" "$SRC_USER lacks CONNECT — run: GRANT CONNECT ON DATABASE <db> TO $SRC_USER"
fi

# Per-schema: USAGE + SELECT on tables/sequences (pg_catalog only)
SCHEMA_PERMS=$(src_query "SELECT n.nspname, has_schema_privilege(current_user, n.nspname, 'USAGE'), (SELECT COUNT(*) FROM pg_class c WHERE c.relnamespace = n.oid AND c.relkind = 'r'), (SELECT COUNT(*) FROM pg_class c WHERE c.relnamespace = n.oid AND c.relkind = 'r' AND NOT has_table_privilege(current_user, c.oid, 'SELECT')), (SELECT COUNT(*) FROM pg_class c WHERE c.relnamespace = n.oid AND c.relkind = 'S'), (SELECT COUNT(*) FROM pg_class c WHERE c.relnamespace = n.oid AND c.relkind = 'S' AND NOT has_sequence_privilege(current_user, c.oid, 'SELECT')) FROM pg_namespace n WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema' ORDER BY n.nspname;")

if [ -z "$SCHEMA_PERMS" ]; then
    warn "Schema read permissions" "no non-system schemas found or query failed"
else
    while IFS='|' read -r schema usage_ok total_tables tables_missing total_seqs seqs_missing; do
        [ -z "$schema" ] && continue
        label="Read perms: $schema"
        if [ "$usage_ok" = "f" ]; then
            fail "$label" "no USAGE on schema — run: GRANT USAGE ON SCHEMA $schema TO $SRC_USER"
        elif [ "${tables_missing:-0}" -gt 0 ] && [ "${seqs_missing:-0}" -gt 0 ]; then
            fail "$label" "missing SELECT on ${tables_missing}/${total_tables} tables, ${seqs_missing}/${total_seqs} sequences"
        elif [ "${tables_missing:-0}" -gt 0 ]; then
            fail "$label" "missing SELECT on ${tables_missing}/${total_tables} tables — run: GRANT SELECT ON ALL TABLES IN SCHEMA $schema TO $SRC_USER"
        elif [ "${seqs_missing:-0}" -gt 0 ]; then
            fail "$label" "missing SELECT on ${seqs_missing}/${total_seqs} sequences — run: GRANT SELECT ON ALL SEQUENCES IN SCHEMA $schema TO $SRC_USER"
        else
            pass "$label" "USAGE + SELECT on ${total_tables} tables, ${total_seqs} sequences"
        fi
    done <<< "$SCHEMA_PERMS"
fi

# ── TARGET DATABASE ────────────────────────────────────────────────
echo ""
echo "  TARGET DATABASE"
echo "  ────────────────────────────────────────────────────────────────"

# 11. Connectivity
TGT_VER=$(tgt_query "SHOW server_version;")
if [ -n "$TGT_VER" ]; then
    pass "Connectivity" "PostgreSQL $TGT_VER"
else
    fail "Connectivity" "cannot connect to target"
    # Skip remaining target checks
    echo ""
    echo "  MIGRATION INSTANCE"
    echo "  ────────────────────────────────────────────────────────────────"
    # Still run local checks below
fi

if [ -n "$TGT_VER" ]; then
    # 12. Replication permission on target
    TGT_REPL=$(tgt_query "SELECT rolreplication FROM pg_roles WHERE rolname = current_user;")
    if [ "$TGT_REPL" = "t" ]; then
        pass "Replication permission" "role has REPLICATION attribute"
    else
        fail "Replication permission" "no REPLICATION attribute (needed for replication origin)"
    fi

    # 13. Existing pgcopydb schema
    PGCOPYDB_SCHEMA=$(tgt_query "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'pgcopydb';")
    if [ -n "$PGCOPYDB_SCHEMA" ]; then
        warn "Existing pgcopydb schema" "pgcopydb schema exists (leftover?)"
    else
        pass "Existing pgcopydb schema" "none"
    fi

    # 14. Extension compatibility
    SRC_EXTS=$(src_query "SELECT extname FROM pg_extension ORDER BY extname;")
    TGT_EXTS=$(tgt_query "SELECT extname FROM pg_extension ORDER BY extname;")
    MISSING_EXTS=""
    SRC_EXT_COUNT=0
    while IFS= read -r ext; do
        [ -z "$ext" ] && continue
        SRC_EXT_COUNT=$((SRC_EXT_COUNT + 1))
        if ! printf '%s\n' "$TGT_EXTS" | grep -qx "$ext"; then
            MISSING_EXTS="${MISSING_EXTS:+$MISSING_EXTS, }$ext"
        fi
    done <<< "$SRC_EXTS"
    if [ -n "$MISSING_EXTS" ]; then
        fail "Extensions" "missing on target: $MISSING_EXTS"
    elif [ "$SRC_EXT_COUNT" -gt 0 ]; then
        pass "Extensions" "all $SRC_EXT_COUNT source extension(s) present on target"
    else
        pass "Extensions" "no extensions on source"
    fi
fi

# ── MIGRATION INSTANCE ─────────────────────────────────────────────
echo ""
echo "  MIGRATION INSTANCE"
echo "  ────────────────────────────────────────────────────────────────"

# 14. filters.ini
if [ -f ~/filters.ini ]; then
    pass "filters.ini" "~/filters.ini found"
else
    fail "filters.ini" "~/filters.ini not found"
fi

# 15. pgcopydb binary
PGCOPYDB_BIN=$(command -v pgcopydb 2>/dev/null || echo "")
if [ -z "$PGCOPYDB_BIN" ] && [ -x /usr/lib/postgresql/17/bin/pgcopydb ]; then
    PGCOPYDB_BIN="/usr/lib/postgresql/17/bin/pgcopydb"
fi
if [ -n "$PGCOPYDB_BIN" ]; then
    pass "pgcopydb binary" "$PGCOPYDB_BIN"
else
    fail "pgcopydb binary" "not found on PATH or /usr/lib/postgresql/17/bin/"
fi

# ── Summary ────────────────────────────────────────────────────────
TOTAL=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))
echo ""
echo "  ══════════════════════════════════════════════════════════════════"
echo -e "  Summary: ${GREEN}$PASS_COUNT passed${NC}, ${YELLOW}$WARN_COUNT warnings${NC}, ${RED}$FAIL_COUNT failed${NC}"
echo "  ══════════════════════════════════════════════════════════════════"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
