-- Runs once, on first container boot, against the FREEPDB1 pluggable database.
-- The gvenzl/oracle-free image auto-creates the APP_USER from env vars BEFORE
-- this script runs, so APP_USER already exists when we get here.

ALTER SESSION SET CONTAINER = QSPDB;

-- Create dedicated tablespaces so partitions and indexes live in named files.
-- IMPORTANT: absolute paths under /opt/oracle/oradata/ — that mount point is
-- the only one persisted in the named docker volume. Relative paths would
-- land in $ORACLE_HOME/dbs/ which is wiped on container recreate.
CREATE TABLESPACE QS_DATA
    DATAFILE '/opt/oracle/oradata/FREE/QSPDB/qs_data01.dbf'
        SIZE 256M AUTOEXTEND ON NEXT 64M MAXSIZE 16G
    EXTENT MANAGEMENT LOCAL AUTOALLOCATE
    SEGMENT SPACE MANAGEMENT AUTO;

CREATE TABLESPACE QS_INDEX
    DATAFILE '/opt/oracle/oradata/FREE/QSPDB/qs_index01.dbf'
        SIZE 128M AUTOEXTEND ON NEXT 32M MAXSIZE 8G
    EXTENT MANAGEMENT LOCAL AUTOALLOCATE
    SEGMENT SPACE MANAGEMENT AUTO;

-- Discover the actual app username (set by APP_USER env var at container boot)
-- and grant it everything it needs for the project.
DECLARE
    v_user VARCHAR2(128);
BEGIN
    SELECT username INTO v_user
      FROM dba_users
     WHERE common = 'NO'
       AND oracle_maintained = 'N'
       AND username NOT IN ('PDBADMIN')
       AND ROWNUM = 1;

    EXECUTE IMMEDIATE 'ALTER USER ' || v_user || ' DEFAULT TABLESPACE QS_DATA';
    EXECUTE IMMEDIATE 'ALTER USER ' || v_user || ' QUOTA UNLIMITED ON QS_DATA';
    EXECUTE IMMEDIATE 'ALTER USER ' || v_user || ' QUOTA UNLIMITED ON QS_INDEX';

    FOR g IN (
        SELECT column_value AS priv FROM TABLE(sys.odcivarchar2list(
            'CREATE SESSION',
            'CREATE TABLE',
            'CREATE VIEW',
            'CREATE MATERIALIZED VIEW',
            'CREATE PROCEDURE',
            'CREATE SEQUENCE',
            'CREATE TYPE',
            'CREATE TRIGGER',
            'CREATE JOB',
            'CREATE SYNONYM',
            'QUERY REWRITE',
            'EXECUTE ANY PROCEDURE'
        ))
    ) LOOP
        EXECUTE IMMEDIATE 'GRANT ' || g.priv || ' TO ' || v_user;
    END LOOP;

    -- Some object-level grants helpful for instrumentation and dynamic SQL.
    EXECUTE IMMEDIATE 'GRANT EXECUTE ON DBMS_APPLICATION_INFO TO ' || v_user;
    EXECUTE IMMEDIATE 'GRANT EXECUTE ON DBMS_SQL TO ' || v_user;
    EXECUTE IMMEDIATE 'GRANT EXECUTE ON DBMS_MVIEW TO ' || v_user;
    EXECUTE IMMEDIATE 'GRANT EXECUTE ON DBMS_LOCK TO ' || v_user;
    EXECUTE IMMEDIATE 'GRANT SELECT ON v_$session TO ' || v_user;
    EXECUTE IMMEDIATE 'GRANT SELECT ON v_$sql TO ' || v_user;
    EXECUTE IMMEDIATE 'GRANT SELECT ON v_$sql_plan TO ' || v_user;
END;
/

EXIT;
