-- =====================================================
-- DMS Source Cleanup Script (PostgreSQL/Cloud SQL)
-- Run this as your postgres/admin user on the SOURCE
-- =====================================================
--
-- Usage:
--   psql -h <source-host> -p <port> -U <username> -d <database> -f dms-source-clean.sql
--
-- Example:
--   psql -h 136.114.25.213 -p 5432 -U postgres -d postgres -f dms-source-clean.sql
--
-- =====================================================

-- Check what DMS objects exist before cleanup
SELECT 'Existing DMS Tables:' as info;
SELECT schemaname, tablename 
FROM pg_tables 
WHERE tablename LIKE 'awsdms_%';

SELECT 'Existing DMS Sequences:' as info;
SELECT schemaname, sequencename 
FROM pg_sequences 
WHERE sequencename LIKE 'awsdms_%';

SELECT 'Existing DMS Publications:' as info;
SELECT pubname FROM pg_publication WHERE pubname LIKE '%dms%';

SELECT 'Existing DMS Replication Slots:' as info;
SELECT slot_name, slot_type, active FROM pg_replication_slots WHERE slot_name LIKE '%dms%';

SELECT 'Existing DMS Event Triggers:' as info;
SELECT evtname FROM pg_event_trigger WHERE evtname LIKE 'awsdms_%';

-- Check pglogical extension and replication sets
SELECT 'Pglogical Extension Status:' as info;
SELECT extname, extversion FROM pg_extension WHERE extname = 'pglogical';

SELECT 'Existing DMS Pglogical Replication Sets:' as info;
DO $$
BEGIN
    IF EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pglogical') THEN
        PERFORM (SELECT set_name, set_nodeid FROM pglogical.replication_set
                WHERE set_name LIKE '%dms%' OR set_name LIKE '%dty%' OR length(set_name) > 50);
    END IF;
END $$;

-- Begin cleanup
DO $$
DECLARE
    r RECORD;
    pglogical_exists BOOLEAN := false;
BEGIN
    RAISE NOTICE 'Starting DMS cleanup on PostgreSQL source...';
    
    -- Check if pglogical extension exists
    SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pglogical') INTO pglogical_exists;
    
    -- 1. Clean up pglogical replication sets (if extension exists)
    IF pglogical_exists THEN
        RAISE NOTICE 'Cleaning up pglogical replication sets...';
        
        -- Remove all tables from DMS replication sets first
        FOR r IN SELECT set_name, schemaname, tablename 
                 FROM pglogical.replication_set_table rst
                 JOIN pglogical.replication_set rs ON rst.set_id = rs.set_id
                 WHERE rs.set_name LIKE '%dms%' OR rs.set_name LIKE '%dty%' OR length(rs.set_name) > 50 LOOP
            BEGIN
                PERFORM pglogical.replication_set_remove_table(r.set_name, r.schemaname || '.' || r.tablename);
                RAISE NOTICE 'Removed table %.% from replication set %', r.schemaname, r.tablename, r.set_name;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Failed to remove table %.% from replication set %: %', r.schemaname, r.tablename, r.set_name, SQLERRM;
            END;
        END LOOP;
        
        -- Drop DMS replication sets
        FOR r IN SELECT set_name FROM pglogical.replication_set 
                 WHERE set_name LIKE '%dms%' OR set_name LIKE '%dty%' OR length(set_name) > 50 LOOP
            BEGIN
                PERFORM pglogical.drop_replication_set(r.set_name);
                RAISE NOTICE 'Dropped replication set: %', r.set_name;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Failed to drop replication set %: %', r.set_name, SQLERRM;
            END;
        END LOOP;
    ELSE
        RAISE NOTICE 'Pglogical extension not found, skipping pglogical cleanup';
    END IF;
    
    -- 2. Drop DMS tables
    RAISE NOTICE 'Dropping DMS tables...';
    FOR r IN SELECT schemaname, tablename FROM pg_tables WHERE tablename LIKE 'awsdms_%' LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.schemaname) || '.' || quote_ident(r.tablename) || ' CASCADE';
        RAISE NOTICE 'Dropped table: %.%', r.schemaname, r.tablename;
    END LOOP;
    
    -- 3. Drop DMS sequences
    RAISE NOTICE 'Dropping DMS sequences...';
    FOR r IN SELECT schemaname, sequencename FROM pg_sequences WHERE sequencename LIKE 'awsdms_%' LOOP
        EXECUTE 'DROP SEQUENCE IF EXISTS ' || quote_ident(r.schemaname) || '.' || quote_ident(r.sequencename) || ' CASCADE';
        RAISE NOTICE 'Dropped sequence: %.%', r.schemaname, r.sequencename;
    END LOOP;
    
    -- 4. Drop DMS event triggers
    RAISE NOTICE 'Dropping DMS event triggers...';
    FOR r IN SELECT evtname FROM pg_event_trigger WHERE evtname LIKE 'awsdms_%' LOOP
        EXECUTE 'DROP EVENT TRIGGER IF EXISTS ' || quote_ident(r.evtname);
        RAISE NOTICE 'Dropped event trigger: %', r.evtname;
    END LOOP;
    
    -- 5. Drop DMS functions
    RAISE NOTICE 'Dropping DMS functions...';
    DROP FUNCTION IF EXISTS awsdms_intercept_ddl_function();
    DROP FUNCTION IF EXISTS awsdms_intercept_truncate_function();
    DROP FUNCTION IF EXISTS awsdms_intercept_drop_function();
    
    -- 6. Drop DMS publications (be careful - check names first)
    RAISE NOTICE 'Dropping DMS publications...';
    FOR r IN SELECT pubname FROM pg_publication WHERE pubname LIKE '%dms%' OR pubname LIKE 'awsdms%' LOOP
        EXECUTE 'DROP PUBLICATION IF EXISTS ' || quote_ident(r.pubname);
        RAISE NOTICE 'Dropped publication: %', r.pubname;
    END LOOP;
    
    -- 7. Drop DMS replication slots (DANGER: only drop confirmed DMS slots)
    RAISE NOTICE 'Dropping DMS replication slots...';
    FOR r IN SELECT slot_name FROM pg_replication_slots WHERE slot_name LIKE '%dms%' AND active = false LOOP
        PERFORM pg_drop_replication_slot(r.slot_name);
        RAISE NOTICE 'Dropped replication slot: %', r.slot_name;
    END LOOP;
    
    -- Warn about active slots
    FOR r IN SELECT slot_name FROM pg_replication_slots WHERE slot_name LIKE '%dms%' AND active = true LOOP
        RAISE WARNING 'Active replication slot not dropped: % - Stop DMS task first', r.slot_name;
    END LOOP;
    
    RAISE NOTICE 'DMS source cleanup completed!';
END $$;

-- Verify cleanup
SELECT 'Remaining DMS objects after cleanup:' as info;
SELECT COUNT(*) as dms_tables FROM pg_tables WHERE tablename LIKE 'awsdms_%';
SELECT COUNT(*) as dms_sequences FROM pg_sequences WHERE sequencename LIKE 'awsdms_%'; 
SELECT COUNT(*) as dms_publications FROM pg_publication WHERE pubname LIKE '%dms%';
SELECT COUNT(*) as dms_slots FROM pg_replication_slots WHERE slot_name LIKE '%dms%';
SELECT COUNT(*) as dms_triggers FROM pg_event_trigger WHERE evtname LIKE 'awsdms_%';

-- Verify pglogical cleanup (if extension exists)
DO $$
BEGIN
    IF EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pglogical') THEN
        RAISE NOTICE 'Remaining DMS pglogical replication sets:';
        PERFORM (SELECT COUNT(*) FROM pglogical.replication_set
                WHERE set_name LIKE '%dms%' OR set_name LIKE '%dty%' OR length(set_name) > 50);
    END IF;
END $$;

SELECT 'Source cleanup verification completed!' as status;