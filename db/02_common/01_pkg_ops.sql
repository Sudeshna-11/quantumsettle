/*
===============================================================================
Package: PKG_OPS
Role:    Shared infrastructure (used by both Optimized and Not-Optimized code)
===============================================================================
Purpose:
    Centralises the bookkeeping every phase needs so the business-logic
    packages can stay focused on their actual work.

Overview:
    Three jobs, bundled here once:
        - record that a run started and how it finished   -> batch_audit
        - record a single rejected input row              -> ingest_errors
        - record an error that must survive a rollback    -> error_log

Entry points:
    begin_batch        Opens a batch_audit row, returns its id.
    end_batch          Closes the row with status, row counts, elapsed time.
    log_ingest_error   One row per rejected input row; called from inside the
                       Ingest phase's FORALL ... SAVE EXCEPTIONS handler.
    log_error          General error capture. Runs as an AUTONOMOUS
                       TRANSACTION so the log row commits independently — the
                       error is still recorded even if the caller rolls back.
===============================================================================
*/


CREATE OR REPLACE PACKAGE pkg_ops AS

    FUNCTION begin_batch (
        p_batch_name       IN VARCHAR2,
        p_batch_type       IN VARCHAR2,
        p_parameters_json  IN CLOB DEFAULT NULL
    ) RETURN NUMBER;

    PROCEDURE end_batch (
        p_batch_id         IN NUMBER,
        p_status           IN VARCHAR2,
        p_rows_processed   IN NUMBER DEFAULT 0,
        p_rows_rejected    IN NUMBER DEFAULT 0,
        p_error_summary    IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE log_ingest_error (
        p_batch_id         IN NUMBER,
        p_source_system    IN VARCHAR2,
        p_external_ref     IN VARCHAR2,
        p_oracle_code      IN NUMBER,
        p_error_message    IN VARCHAR2,
        p_row_payload      IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE log_error (
        p_module     IN VARCHAR2,
        p_operation  IN VARCHAR2,
        p_code       IN NUMBER,
        p_message    IN VARCHAR2,
        p_stack      IN CLOB DEFAULT NULL
    );

END pkg_ops;
/


CREATE OR REPLACE PACKAGE BODY pkg_ops AS

    ---------------------------------------------------------------------------
    -- begin_batch
    ---------------------------------------------------------------------------
    FUNCTION begin_batch (
        p_batch_name       IN VARCHAR2,
        p_batch_type       IN VARCHAR2,
        p_parameters_json  IN CLOB DEFAULT NULL
    ) RETURN NUMBER IS
        v_id NUMBER;
    BEGIN
        INSERT INTO batch_audit (batch_id, batch_name, batch_type, started_at,
                                 status, parameters_json)
        VALUES (seq_batch_id.NEXTVAL, p_batch_name, p_batch_type, SYSTIMESTAMP,
                'RUNNING', p_parameters_json)
        RETURNING batch_id INTO v_id;

        DBMS_APPLICATION_INFO.SET_MODULE(p_batch_type, p_batch_name);
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO('batch_id=' || v_id);
        COMMIT;
        RETURN v_id;
    END begin_batch;

    ---------------------------------------------------------------------------
    -- end_batch
    ---------------------------------------------------------------------------
    PROCEDURE end_batch (
        p_batch_id         IN NUMBER,
        p_status           IN VARCHAR2,
        p_rows_processed   IN NUMBER DEFAULT 0,
        p_rows_rejected    IN NUMBER DEFAULT 0,
        p_error_summary    IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        UPDATE batch_audit
           SET completed_at   = SYSTIMESTAMP,
               status         = p_status,
               rows_processed = p_rows_processed,
               rows_rejected  = p_rows_rejected,
               -- Cast both sides to DATE to side-step timezone arithmetic;
               -- second resolution is fine for a batch-level metric. The
               -- benchmark harness uses DBMS_UTILITY.GET_TIME for sub-second
               -- timing instead.
               elapsed_ms     = ROUND((CAST(SYSTIMESTAMP AS DATE)
                                       - CAST(started_at AS DATE)) * 86400 * 1000),
               error_summary  = p_error_summary
         WHERE batch_id = p_batch_id;

        DBMS_APPLICATION_INFO.SET_MODULE(NULL, NULL);
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL);
        COMMIT;
    END end_batch;

    ---------------------------------------------------------------------------
    -- log_ingest_error
    ---------------------------------------------------------------------------
    PROCEDURE log_ingest_error (
        p_batch_id         IN NUMBER,
        p_source_system    IN VARCHAR2,
        p_external_ref     IN VARCHAR2,
        p_oracle_code      IN NUMBER,
        p_error_message    IN VARCHAR2,
        p_row_payload      IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        INSERT INTO ingest_errors (error_id, batch_id, source_system,
                                   external_trade_ref, oracle_error_code,
                                   error_message, row_payload)
        VALUES (seq_ingest_err.NEXTVAL, p_batch_id, p_source_system,
                p_external_ref, p_oracle_code, SUBSTR(p_error_message, 1, 500),
                SUBSTR(p_row_payload, 1, 2000));
    END log_ingest_error;

    ---------------------------------------------------------------------------
    -- log_error  (autonomous transaction)
    ---------------------------------------------------------------------------
    PROCEDURE log_error (
        p_module     IN VARCHAR2,
        p_operation  IN VARCHAR2,
        p_code       IN NUMBER,
        p_message    IN VARCHAR2,
        p_stack      IN CLOB DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO error_log (error_id, module_name, operation, oracle_code,
                               error_message, call_stack, session_id)
        VALUES (seq_error_id.NEXTVAL, p_module, p_operation, p_code,
                SUBSTR(p_message, 1, 1000), p_stack,
                SYS_CONTEXT('USERENV','SESSIONID'));
        COMMIT;
    END log_error;

END pkg_ops;
/
