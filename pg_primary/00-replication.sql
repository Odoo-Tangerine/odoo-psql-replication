-- Create a replication user (idempotent: only creates if not exists)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
        CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpass';
    END IF;
END$$;

-- Create a physical replication slot for the replica (harmless if later recreated)
SELECT CASE
         WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica1')
           THEN 'replica1 exists'
         ELSE (SELECT slot_name FROM pg_create_physical_replication_slot('replica1'))
       END;
