#!/bin/bash
#
# Usage: ~/target-clean.sh
#
# Wipes all user objects from the target database for a fresh re-migration.
# Shows a summary of what will be dropped and prompts for confirmation.
# Drops all non-default schemas, recreates public, and verifies no stale
# custom types remain. Never uses "DROP OWNED BY" (causes composite type issues).
#
set -e

# --- Load environment ---
set +u
set -a
source ~/.env
set +a
set -u

if [ -z "${PGCOPYDB_TARGET_PGURI:-}" ]; then
    echo "ERROR: PGCOPYDB_TARGET_PGURI must be set in ~/.env"
    exit 1
fi
# --- loaded ---

echo "=========================================="
echo "Quick Clean: Target Database"
echo "=========================================="
echo ""
echo "Analyzing target database..."
echo ""

# Summary of what exists
psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT 'Schemas:            ' || count(*)
FROM pg_namespace n
WHERE nspname NOT IN ('pg_catalog','information_schema','pg_toast','pscale_extensions','public')
  AND nspname NOT LIKE 'pg_temp%' AND nspname NOT LIKE 'pg_toast_temp%'
  AND NOT EXISTS (SELECT 1 FROM pg_extension e WHERE e.extnamespace = n.oid);"

psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT 'Tables:             ' || count(*)
FROM pg_tables t
WHERE schemaname NOT IN ('pg_catalog','information_schema')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relname = t.tablename AND n.nspname = t.schemaname) AND d.deptype = 'e');"

psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT 'Indexes:            ' || count(*)
FROM pg_indexes i
WHERE schemaname NOT IN ('pg_catalog','information_schema','pg_toast')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relname = i.indexname AND n.nspname = i.schemaname) AND d.deptype = 'e');"

psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT 'Views:              ' || count(*)
FROM pg_views v
WHERE schemaname NOT IN ('pg_catalog','information_schema')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relname = v.viewname AND n.nspname = v.schemaname) AND d.deptype = 'e');"

psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT 'Materialized views: ' || count(*) FROM pg_matviews;"

psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT 'Sequences:          ' || count(*)
FROM pg_sequences s
WHERE schemaname NOT IN ('pg_catalog','information_schema')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relname = s.sequencename AND n.nspname = s.schemaname) AND d.deptype = 'e');"

psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT 'Custom types:       ' || count(*)
FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid
WHERE t.typtype IN ('c','e')
  AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast','pscale_extensions')
  AND t.typname NOT LIKE 'pg_%'
  AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.reltype = t.oid AND c.relkind IN ('r','v','m','p','f'))
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e');"

psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT 'Functions:          ' || count(*)
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog','information_schema','pscale_extensions')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e');"

psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT 'Aggregates:         ' || count(*)
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog','information_schema','pscale_extensions')
  AND p.prokind = 'a'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e');"

psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT 'Extensions:         ' || count(*)
FROM pg_extension WHERE extname != 'plpgsql';"

echo ""
echo "Tables by schema:"
psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT '  ' || t.schemaname || ': ' || count(*)
FROM pg_tables t
WHERE t.schemaname NOT IN ('pg_catalog','information_schema')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relname = t.tablename AND n.nspname = t.schemaname) AND d.deptype = 'e')
GROUP BY t.schemaname ORDER BY count(*) DESC;" | head -15

echo ""
echo "Functions by schema (non-extension-owned):"
psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT '  ' || n.nspname || ': ' || count(*)
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog','information_schema','pscale_extensions')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
GROUP BY n.nspname ORDER BY count(*) DESC;" | head -15

echo ""
read -p "Drop ALL of this and start fresh? [y/N] " confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "Cleaning..."

echo "  Dropping materialized views..."
psql "$PGCOPYDB_TARGET_PGURI" -t -c "
SELECT 'DROP MATERIALIZED VIEW IF EXISTS ' || quote_ident(schemaname) || '.' || quote_ident(matviewname) || ' CASCADE;'
FROM pg_matviews;" | psql "$PGCOPYDB_TARGET_PGURI" 2>/dev/null || true

echo "  Dropping views (non-extension-owned)..."
psql "$PGCOPYDB_TARGET_PGURI" -t -c "
SELECT 'DROP VIEW IF EXISTS ' || quote_ident(schemaname) || '.' || quote_ident(viewname) || ' CASCADE;'
FROM pg_views
WHERE schemaname NOT IN ('pg_catalog','information_schema')
  AND NOT EXISTS (
    SELECT 1 FROM pg_depend d
    WHERE d.objid = (
      SELECT c.oid FROM pg_class c
      JOIN pg_namespace n ON c.relnamespace = n.oid
      WHERE c.relname = viewname AND n.nspname = schemaname
    ) AND d.deptype = 'e'
  );" | psql "$PGCOPYDB_TARGET_PGURI" 2>/dev/null || true

echo "  Dropping all publications and subscriptions..."
psql "$PGCOPYDB_TARGET_PGURI" -t -c "
SELECT 'DROP PUBLICATION IF EXISTS ' || quote_ident(pubname) || ' CASCADE;'
FROM pg_publication;" | psql "$PGCOPYDB_TARGET_PGURI" 2>/dev/null || true
psql "$PGCOPYDB_TARGET_PGURI" -t -c "
SELECT 'DROP SUBSCRIPTION IF EXISTS ' || quote_ident(subname) || ' CASCADE;'
FROM pg_subscription;" | psql "$PGCOPYDB_TARGET_PGURI" 2>/dev/null || true

echo "  Dropping event triggers..."
psql "$PGCOPYDB_TARGET_PGURI" -t -c "
SELECT 'DROP EVENT TRIGGER IF EXISTS ' || quote_ident(evtname) || ' CASCADE;'
FROM pg_event_trigger;" | psql "$PGCOPYDB_TARGET_PGURI" 2>/dev/null || true

echo "  Dropping non-extension-owned aggregates..."
psql "$PGCOPYDB_TARGET_PGURI" -t -c "
SELECT 'DROP AGGREGATE IF EXISTS ' || quote_ident(n.nspname) || '.' || quote_ident(p.proname) || '('
       || pg_get_function_identity_arguments(p.oid) || ') CASCADE;'
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog','information_schema','pscale_extensions')
  AND p.prokind = 'a'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e');" \
  | psql "$PGCOPYDB_TARGET_PGURI" 2>/dev/null || true

echo "  Dropping non-extension-owned functions..."
psql "$PGCOPYDB_TARGET_PGURI" -t -c "
SELECT 'DROP FUNCTION IF EXISTS ' || quote_ident(n.nspname) || '.' || quote_ident(p.proname) || '('
       || pg_get_function_identity_arguments(p.oid) || ') CASCADE;'
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog','information_schema','pscale_extensions')
  AND p.prokind IN ('f', 'w')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e');" \
  | psql "$PGCOPYDB_TARGET_PGURI" 2>/dev/null || true

echo "  Dropping non-extension-owned procedures..."
psql "$PGCOPYDB_TARGET_PGURI" -t -c "
SELECT 'DROP PROCEDURE IF EXISTS ' || quote_ident(n.nspname) || '.' || quote_ident(p.proname) || '('
       || pg_get_function_identity_arguments(p.oid) || ') CASCADE;'
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog','information_schema','pscale_extensions')
  AND p.prokind = 'p'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e');" \
  | psql "$PGCOPYDB_TARGET_PGURI" 2>/dev/null || true

echo "  Dropping standalone custom types (enums + composites)..."
psql "$PGCOPYDB_TARGET_PGURI" -t -c "
SELECT 'DROP TYPE IF EXISTS ' || quote_ident(n.nspname) || '.' || quote_ident(t.typname) || ' CASCADE;'
FROM pg_type t
JOIN pg_namespace n ON t.typnamespace = n.oid
WHERE t.typtype IN ('c', 'e')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'pscale_extensions')
  AND t.typname NOT LIKE 'pg_%'
  AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.reltype = t.oid AND c.relkind IN ('r','v','m','p','f'))
ORDER BY n.nspname, t.typname;" | psql "$PGCOPYDB_TARGET_PGURI" 2>/dev/null || true

echo "  Dropping non-default schemas (excluding extension-owned)..."
psql "$PGCOPYDB_TARGET_PGURI" -t -c "
SELECT 'DROP SCHEMA IF EXISTS ' || quote_ident(n.nspname) || ' CASCADE;'
FROM pg_namespace n
WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast','public','pscale_extensions')
  AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast_temp%'
  AND NOT EXISTS (SELECT 1 FROM pg_extension e WHERE e.extnamespace = n.oid);" \
  | psql "$PGCOPYDB_TARGET_PGURI" 2>/dev/null || true

echo "  Dropping partitioned tables in public..."
psql "$PGCOPYDB_TARGET_PGURI" -t -c "
SELECT 'DROP TABLE IF EXISTS public.' || quote_ident(relname) || ' CASCADE;'
FROM pg_class
WHERE relkind = 'p'
  AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
ORDER BY relname;" | psql "$PGCOPYDB_TARGET_PGURI" 2>/dev/null || true

echo "  Dropping and recreating public schema..."
psql "$PGCOPYDB_TARGET_PGURI" -c "DROP SCHEMA IF EXISTS public CASCADE;"
psql "$PGCOPYDB_TARGET_PGURI" -c "CREATE SCHEMA public;"
psql "$PGCOPYDB_TARGET_PGURI" -c "GRANT ALL ON SCHEMA public TO postgres;"
psql "$PGCOPYDB_TARGET_PGURI" -c "GRANT ALL ON SCHEMA public TO public;"

echo ""
echo "  Verifying cleanup..."

REMAINING_TYPES=$(psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT count(*)
FROM pg_type t
JOIN pg_namespace n ON t.typnamespace = n.oid
WHERE t.typtype IN ('c', 'e')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'pscale_extensions')
  AND t.typname NOT LIKE 'pg_%'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e');" | tr -d ' ')

REMAINING_FUNCS=$(psql "$PGCOPYDB_TARGET_PGURI" --no-align -t -c "
SELECT count(*)
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog','information_schema','pscale_extensions')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e');" | tr -d ' ')

if [ "$REMAINING_TYPES" -gt "0" ]; then
    echo "  WARNING: $REMAINING_TYPES custom types still remain!"
    psql "$PGCOPYDB_TARGET_PGURI" -c "
    SELECT n.nspname, t.typname, t.typtype
    FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid
    WHERE t.typtype IN ('c', 'e')
      AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast','pscale_extensions')
      AND t.typname NOT LIKE 'pg_%'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e')
    ORDER BY n.nspname, t.typname LIMIT 20;"
else
    echo "  OK: No stale custom types found."
fi

if [ "$REMAINING_FUNCS" -gt "0" ]; then
    echo "  WARNING: $REMAINING_FUNCS non-extension functions still remain!"
    psql "$PGCOPYDB_TARGET_PGURI" -c "
    SELECT n.nspname, p.proname, p.prokind
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname NOT IN ('pg_catalog','information_schema','pscale_extensions')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
    ORDER BY n.nspname, p.proname LIMIT 20;"
else
    echo "  OK: No stale non-extension functions found."
fi

echo ""
echo "=========================================="
echo "Done! Target database is clean."
echo "=========================================="
