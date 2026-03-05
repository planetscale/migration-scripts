#!/bin/bash
#
# Usage: ~/fix-replica-identity.sh
#
# Finds tables on the source that have default replica identity and no
# primary key or unique index, then sets them to REPLICA IDENTITY FULL.
# Required for CDC to work on tables without natural keys. Previews the
# ALTER statements and prompts before applying.
#

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

echo "Finding tables with default replica identity and no usable unique index..."

psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c "
SELECT 'ALTER TABLE ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ' REPLICA IDENTITY FULL;'
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND c.relreplident = 'd'
  AND n.nspname NOT LIKE 'pg_%'
  AND n.nspname != 'information_schema'
  AND NOT EXISTS (
    SELECT 1 FROM pg_constraint con
    WHERE con.conrelid = c.oid
      AND con.contype IN ('p', 'u')
  )
ORDER BY n.nspname, c.relname;
" > /tmp/replica-identity-statements.sql

COUNT=$(grep -c '.' /tmp/replica-identity-statements.sql || true)
echo "Found $COUNT tables needing REPLICA IDENTITY FULL."
echo ""
echo "Preview (first 10):"
head -10 /tmp/replica-identity-statements.sql
echo "..."
echo ""
read -p "Run all $COUNT ALTER statements on source? [y/N] " confirm

if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    echo "Running ALTER TABLE statements..."
    psql "$PGCOPYDB_SOURCE_PGURI" -f /tmp/replica-identity-statements.sql
    echo "Done. All $COUNT tables set to REPLICA IDENTITY FULL."
else
    echo "Aborted. Statements saved to /tmp/replica-identity-statements.sql"
fi
