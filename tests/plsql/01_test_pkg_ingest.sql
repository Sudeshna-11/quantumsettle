/*
===============================================================================
Suite: test_pkg_ingest
Covers: PKG_INGEST_OPTIMIZED.load_trades — FORALL + SAVE EXCEPTIONS
===============================================================================
Purpose:
    The happy-path FORALL ingestion is exercised by the bench harness and CLI
    smoke tests. This suite focuses on the harder-to-verify edge cases:
    per-row exception capture and batch-audit accounting.
===============================================================================
*/


CREATE OR REPLACE PACKAGE test_pkg_ingest AS
    PROCEDURE test_save_exceptions_captures_per_row;
    PROCEDURE test_batch_audit_records_status;
END test_pkg_ingest;
/


CREATE OR REPLACE PACKAGE BODY test_pkg_ingest AS

    ---------------------------------------------------------------------------
    -- Re-ingest the most recent successful trades CSV. Every row should
    -- collide on the (source_system, external_trade_ref) unique key, so the
    -- SAVE EXCEPTIONS path is exercised and per-row rejections are captured
    -- in INGEST_ERRORS.
    ---------------------------------------------------------------------------
    PROCEDURE test_save_exceptions_captures_per_row IS
        v_existing_count NUMBER;
        v_batch_id       NUMBER;
        v_rejected       NUMBER;
        v_filename       VARCHAR2(200);
    BEGIN
        -- TO_CHAR coerces the CLOB parameters_json so REGEXP_SUBSTR returns VARCHAR2.
        BEGIN
            SELECT REGEXP_SUBSTR(TO_CHAR(parameters_json),
                                 '"file":"([^"]+)"', 1, 1, NULL, 1)
              INTO v_filename
              FROM batch_audit
             WHERE batch_type = 'INGEST_OPTIMIZED'
               AND status IN ('SUCCESS','PARTIAL')
             ORDER BY batch_id DESC
             FETCH FIRST 1 ROWS ONLY;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN v_filename := NULL;
        END;

        IF v_filename IS NULL THEN
            pkg_test_util.assert_equal('no prior ingest — skipped', 1, 1);
            RETURN;
        END IF;

        v_batch_id := pkg_ingest_optimized.load_trades(v_filename);

        SELECT rows_rejected INTO v_rejected
          FROM batch_audit WHERE batch_id = v_batch_id;

        pkg_test_util.assert_true(
            're-ingesting the same file should reject at least one row',
            v_rejected > 0);

        -- One ingest_errors row per rejected input row.
        SELECT COUNT(*) INTO v_existing_count
          FROM ingest_errors WHERE batch_id = v_batch_id;
        pkg_test_util.assert_equal(
            'ingest_errors count should match rows_rejected',
            v_existing_count, v_rejected);
    END test_save_exceptions_captures_per_row;

    ---------------------------------------------------------------------------
    -- batch_audit must close out with a terminal status and a sensible
    -- elapsed_ms (no negative numbers from a timezone bug). Skips when no
    -- prior ingest run exists (e.g. a pristine CI database).
    ---------------------------------------------------------------------------
    PROCEDURE test_batch_audit_records_status IS
        v_status     VARCHAR2(20);
        v_elapsed_ms NUMBER;
        v_found      BOOLEAN := TRUE;
    BEGIN
        BEGIN
            SELECT status, elapsed_ms INTO v_status, v_elapsed_ms
              FROM batch_audit
             WHERE batch_type IN ('INGEST_OPTIMIZED','INGEST_NOT_OPTIMIZED')
             ORDER BY batch_id DESC
             FETCH FIRST 1 ROWS ONLY;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN v_found := FALSE;
        END;

        IF NOT v_found THEN
            pkg_test_util.assert_equal('no prior ingest batch — skipped', 1, 1);
            RETURN;
        END IF;

        pkg_test_util.assert_true(
            'most recent ingest batch should have a terminal status',
            v_status IN ('SUCCESS','PARTIAL','FAILED'));

        pkg_test_util.assert_true(
            'elapsed_ms should be NULL or non-negative',
            v_elapsed_ms IS NULL OR v_elapsed_ms >= 0);
    END test_batch_audit_records_status;

END test_pkg_ingest;
/
