/*
===============================================================================
Package: PKG_PERF
Role:    Shared infrastructure (used by both Optimized and Not-Optimized code)
===============================================================================
Purpose:
    The measurement toolkit. Times operations for the benchmark, captures
    execution plans for the perf story, and resets the fact tables between
    benchmark runs.

Overview:
    start_run / end_run bracket an operation and record its elapsed time into
    perf_metrics, tagged with the variant ('OPTIMIZED' or 'NOT_OPTIMIZED').
    explain_plan captures DBMS_XPLAN output for any SQL string without
    executing it. reset_for_bench empties the trade tables so each benchmark
    starts from a known state.

Entry points:
    start_run        Opens a perf_metrics row, returns metric_id.
    end_run          Closes it with elapsed_ms (and optional row count).
    explain_plan     EXPLAIN PLAN FOR <sql>, returns the formatted plan CLOB.
    reset_for_bench  TRUNCATEs trades + ingest_errors and rebuilds the MV log
                     so a benchmark run starts clean.

Design note:
    Elapsed time uses DBMS_UTILITY.GET_TIME (hundredths of a second, monotonic)
    rather than SYSTIMESTAMP — no timezone or clock-adjustment surprises when
    measuring a duration.
===============================================================================
*/


CREATE OR REPLACE PACKAGE pkg_perf AS

    FUNCTION start_run (
        p_operation_name IN VARCHAR2,
        p_variant        IN VARCHAR2,
        p_notes          IN VARCHAR2 DEFAULT NULL
    ) RETURN NUMBER;

    PROCEDURE end_run (
        p_metric_id      IN NUMBER,
        p_rows_processed IN NUMBER DEFAULT NULL
    );

    FUNCTION explain_plan (
        p_sql    IN CLOB,
        p_format IN VARCHAR2 DEFAULT 'TYPICAL +PARTITION'
    ) RETURN CLOB;

    PROCEDURE reset_for_bench;

END pkg_perf;
/


CREATE OR REPLACE PACKAGE BODY pkg_perf AS

    -- DBMS_UTILITY.GET_TIME start values, keyed by metric_id. PL/SQL package
    -- state is session-scoped, so benchmark runs in separate sessions don't
    -- interfere with each other.
    TYPE t_start_map IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    g_starts t_start_map;

    ---------------------------------------------------------------------------
    -- start_run
    ---------------------------------------------------------------------------
    FUNCTION start_run (
        p_operation_name IN VARCHAR2,
        p_variant        IN VARCHAR2,
        p_notes          IN VARCHAR2 DEFAULT NULL
    ) RETURN NUMBER IS
        v_id NUMBER;
    BEGIN
        INSERT INTO perf_metrics (
            metric_id, operation_name, variant, rows_processed,
            elapsed_ms, notes, captured_at
        ) VALUES (
            seq_metric_id.NEXTVAL, p_operation_name, p_variant, NULL,
            NULL, p_notes, SYSTIMESTAMP
        ) RETURNING metric_id INTO v_id;

        g_starts(v_id) := DBMS_UTILITY.GET_TIME;
        COMMIT;
        RETURN v_id;
    END start_run;

    ---------------------------------------------------------------------------
    -- end_run
    ---------------------------------------------------------------------------
    PROCEDURE end_run (
        p_metric_id      IN NUMBER,
        p_rows_processed IN NUMBER DEFAULT NULL
    ) IS
        v_elapsed_cs NUMBER;
    BEGIN
        IF NOT g_starts.EXISTS(p_metric_id) THEN
            RAISE_APPLICATION_ERROR(-20001,
                'pkg_perf.end_run: no start recorded for metric_id=' || p_metric_id);
        END IF;

        v_elapsed_cs := DBMS_UTILITY.GET_TIME - g_starts(p_metric_id);
        g_starts.DELETE(p_metric_id);

        UPDATE perf_metrics
           SET elapsed_ms     = v_elapsed_cs * 10,   -- hundredths -> milliseconds
               rows_processed = p_rows_processed
         WHERE metric_id = p_metric_id;
        COMMIT;
    END end_run;

    ---------------------------------------------------------------------------
    -- explain_plan
    ---------------------------------------------------------------------------
    FUNCTION explain_plan (
        p_sql    IN CLOB,
        p_format IN VARCHAR2 DEFAULT 'TYPICAL +PARTITION'
    ) RETURN CLOB IS
        v_stmt_id  VARCHAR2(40) := 'QS_' || DBMS_RANDOM.STRING('U', 16);
        v_plan     CLOB         := '';
    BEGIN
        EXECUTE IMMEDIATE
            'EXPLAIN PLAN SET STATEMENT_ID = ''' || v_stmt_id || ''' FOR ' || p_sql;

        FOR r IN (
            SELECT plan_table_output
              FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', v_stmt_id, p_format))
        ) LOOP
            v_plan := v_plan || r.plan_table_output || CHR(10);
        END LOOP;

        DELETE FROM plan_table WHERE statement_id = v_stmt_id;
        COMMIT;
        RETURN v_plan;
    END explain_plan;

    ---------------------------------------------------------------------------
    -- reset_for_bench
    --
    -- Empties the two tables a benchmark writes to (trades, ingest_errors) and
    -- rebuilds the MV log so MV_DAILY_PNL starts empty too. The MV log has to
    -- be dropped before TRUNCATE and recreated afterwards.
    ---------------------------------------------------------------------------
    PROCEDURE reset_for_bench IS
    BEGIN
        EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW LOG ON trades';

        EXECUTE IMMEDIATE 'TRUNCATE TABLE trades        DROP STORAGE';
        EXECUTE IMMEDIATE 'TRUNCATE TABLE ingest_errors DROP STORAGE';

        EXECUTE IMMEDIATE q'[
            CREATE MATERIALIZED VIEW LOG ON trades
                WITH ROWID, SEQUENCE (
                    trade_date, account_id, currency, side,
                    quantity, gross_amount, net_amount, commission
                )
                INCLUDING NEW VALUES
        ]';

        -- Clear MV_DAILY_PNL of any rows left over from the previous run.
        DBMS_MVIEW.REFRESH('MV_DAILY_PNL', 'C');
    END reset_for_bench;

END pkg_perf;
/
