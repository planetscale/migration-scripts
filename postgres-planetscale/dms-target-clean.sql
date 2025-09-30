-- =====================================================
-- DMS Target Cleanup Script (PlanetScale PostgreSQL)
-- Run this on your PlanetScale TARGET database
-- =====================================================
--
-- Usage:
--   psql -h <target-host> -p <port> -U <username> -d <database> -f dms-target-clean.sql
--
-- Example:
--   psql -h mydb.us-east-1.psdb.cloud -p 5432 -U myuser -d postgres -f dms-target-clean.sql
--
-- =====================================================

-- Check existing DMS objects
SELECT 'Existing DMS Tables:' as info;
SELECT schemaname, tablename
FROM pg_tables
WHERE tablename LIKE 'awsdms_%';

SELECT 'Existing DMS Sequences:' as info;
SELECT schemaname, sequencename
FROM pg_sequences
WHERE sequencename LIKE 'awsdms_%';

-- Begin cleanup
DO $$
DECLARE
    r RECORD;
BEGIN
    RAISE NOTICE 'Starting DMS cleanup on PlanetScale PostgreSQL target...';

    -- Drop DMS tables
    RAISE NOTICE 'Dropping DMS tables...';
    FOR r IN SELECT schemaname, tablename FROM pg_tables WHERE tablename LIKE 'awsdms_%' LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.schemaname) || '.' || quote_ident(r.tablename) || ' CASCADE';
        RAISE NOTICE 'Dropped table: %.%', r.schemaname, r.tablename;
    END LOOP;

    -- Drop DMS sequences
    RAISE NOTICE 'Dropping DMS sequences...';
    FOR r IN SELECT schemaname, sequencename FROM pg_sequences WHERE sequencename LIKE 'awsdms_%' LOOP
        EXECUTE 'DROP SEQUENCE IF EXISTS ' || quote_ident(r.schemaname) || '.' || quote_ident(r.sequencename) || ' CASCADE';
        RAISE NOTICE 'Dropped sequence: %.%', r.schemaname, r.sequencename;
    END LOOP;

    -- Drop DMS functions if they exist
    RAISE NOTICE 'Dropping DMS functions...';
    DROP FUNCTION IF EXISTS awsdms_intercept_ddl_function();
    DROP FUNCTION IF EXISTS awsdms_intercept_truncate_function();
    DROP FUNCTION IF EXISTS awsdms_intercept_drop_function();

    RAISE NOTICE 'DMS target cleanup completed!';
END $$;

-- Verify cleanup
SELECT 'Remaining DMS objects after cleanup:' as info;
SELECT COUNT(*) as dms_tables FROM pg_tables WHERE tablename LIKE 'awsdms_%';
SELECT COUNT(*) as dms_sequences FROM pg_sequences WHERE sequencename LIKE 'awsdms_%';

-- Check your business tables status (optional)
SELECT 'Your business tables:' as info;
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size
FROM pg_tables
WHERE schemaname = 'public'
    AND tablename NOT LIKE 'awsdms_%'
ORDER BY tablename;

SELECT 'Target cleanup verification completed! Ready for DMS migration.' as status;