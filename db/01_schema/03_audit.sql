/*
===============================================================================
DDL: Audit, error and performance-metric tables
===============================================================================
Purpose:
    The observability tables every package writes to. None of these are
    partitioned — they stay small relative to TRADES.

Overview:
    - batch_audit    one row per package run (start, end, status, row counts)
    - ingest_errors  one row per rejected input row, captured by the Ingest
                     phase's SAVE EXCEPTIONS handler
    - error_log      general error capture, written via autonomous transaction
                     so it survives a rollback in the calling code
    - perf_metrics   one row per timed operation; the Optimized-vs-Not-Optimized
                     benchmark numbers live here and feed the dashboard chart
===============================================================================
*/


-------------------------------------------------------------------------------
-- sequences
-------------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS seq_batch_id   START WITH 1 INCREMENT BY 1 NOCACHE
/
CREATE SEQUENCE IF NOT EXISTS seq_ingest_err START WITH 1 INCREMENT BY 1 CACHE 100
/
CREATE SEQUENCE IF NOT EXISTS seq_error_id   START WITH 1 INCREMENT BY 1 CACHE 100
/
CREATE SEQUENCE IF NOT EXISTS seq_metric_id  START WITH 1 INCREMENT BY 1 CACHE 100
/


-------------------------------------------------------------------------------
-- batch_audit  (one row per package run)
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS batch_audit (
    batch_id        NUMBER(15)     NOT NULL,
    batch_name      VARCHAR2(60)   NOT NULL,
    batch_type      VARCHAR2(30)   NOT NULL,
    started_at      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    completed_at    TIMESTAMP,
    status          VARCHAR2(20)   DEFAULT 'RUNNING' NOT NULL,
    rows_processed  NUMBER         DEFAULT 0 NOT NULL,
    rows_rejected   NUMBER         DEFAULT 0 NOT NULL,
    elapsed_ms      NUMBER,
    error_summary   VARCHAR2(500),
    parameters_json CLOB,

    CONSTRAINT pk_batch_audit    PRIMARY KEY (batch_id),
    CONSTRAINT ck_batch_audit_st CHECK (status IN ('RUNNING','SUCCESS','FAILED','PARTIAL'))
) TABLESPACE qs_data
/

CREATE INDEX IF NOT EXISTS ix_batch_audit_started
    ON batch_audit (started_at DESC) TABLESPACE qs_index
/


-------------------------------------------------------------------------------
-- ingest_errors  (one row per rejected input row)
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ingest_errors (
    error_id            NUMBER(15)    NOT NULL,
    batch_id            NUMBER(15)    NOT NULL,
    source_system       VARCHAR2(20),
    external_trade_ref  VARCHAR2(40),
    oracle_error_code   NUMBER,
    error_message       VARCHAR2(500),
    row_payload         VARCHAR2(2000),
    created_at          TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT pk_ingest_errors PRIMARY KEY (error_id)
) TABLESPACE qs_data
/

CREATE INDEX IF NOT EXISTS ix_ingest_errors_batch
    ON ingest_errors (batch_id) TABLESPACE qs_index
/


-------------------------------------------------------------------------------
-- error_log  (general error capture)
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS error_log (
    error_id      NUMBER(15)    NOT NULL,
    error_ts      TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    module_name   VARCHAR2(60),
    operation     VARCHAR2(120),
    oracle_code   NUMBER,
    error_message VARCHAR2(1000),
    call_stack    CLOB,
    session_id    NUMBER,

    CONSTRAINT pk_error_log PRIMARY KEY (error_id)
) TABLESPACE qs_data
/

CREATE INDEX IF NOT EXISTS ix_error_log_ts
    ON error_log (error_ts DESC) TABLESPACE qs_index
/


-------------------------------------------------------------------------------
-- perf_metrics  (one row per timed operation)
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS perf_metrics (
    metric_id       NUMBER(15)    NOT NULL,
    batch_id        NUMBER(15),
    operation_name  VARCHAR2(80)  NOT NULL,
    variant         VARCHAR2(20)  NOT NULL,
    rows_processed  NUMBER,
    elapsed_ms      NUMBER,
    cpu_ms          NUMBER,
    db_reads        NUMBER,
    db_writes       NUMBER,
    notes           VARCHAR2(400),
    captured_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT pk_perf_metrics PRIMARY KEY (metric_id),
    CONSTRAINT ck_perf_variant CHECK (variant IN ('OPTIMIZED','NOT_OPTIMIZED','BASELINE'))
) TABLESPACE qs_data
/

CREATE INDEX IF NOT EXISTS ix_perf_metrics_op_var
    ON perf_metrics (operation_name, variant, captured_at)
    TABLESPACE qs_index
/
