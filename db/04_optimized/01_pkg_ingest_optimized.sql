/*
===============================================================================
Package: PKG_INGEST_OPTIMIZED
Phase:   1 of 3 — Ingest
Version: Optimized
===============================================================================
Purpose:
    Loads a staged CSV of raw trades into the partitioned TRADES table.

Overview:
    Reads from the EXT_TRADES external table in chunks and writes each chunk
    with a single FORALL ... SAVE EXCEPTIONS INSERT. One SQL round-trip per
    5,000-row chunk instead of one per row.

Optimization techniques:
    - BULK COLLECT with a LIMIT clause: chunked fetch, bounded PGA memory.
    - FORALL array binding: one PL/SQL-to-SQL context switch per chunk, not
      per row. This is the throughput win.
    - SAVE EXCEPTIONS: a bad row is captured into SQL%BULK_EXCEPTIONS and
      logged to INGEST_ERRORS; the rest of the chunk still commits.

Compare with:
    PKG_INGEST_NOT_OPTIMIZED — same job, row-by-row cursor loop.

Usage:
    v_batch_id := pkg_ingest_optimized.load_trades('trades_2026.csv');
===============================================================================
*/


CREATE OR REPLACE PACKAGE pkg_ingest_optimized AS

    /*
     * Load trades from data/staged/<p_filename> via the EXT_TRADES external
     * table. Returns the batch_id; query BATCH_AUDIT for the run result.
     */
    FUNCTION load_trades (
        p_filename    IN VARCHAR2,
        p_chunk_size  IN PLS_INTEGER DEFAULT 5000
    ) RETURN NUMBER;

END pkg_ingest_optimized;
/


CREATE OR REPLACE PACKAGE BODY pkg_ingest_optimized AS

    -- Strongly typed row buffer for BULK COLLECT. Note: no net_amount or
    -- settlement_date — those are derived later by the Process phase.
    TYPE t_trade_row IS RECORD (
        external_trade_ref  trades.external_trade_ref%TYPE,
        source_system       trades.source_system%TYPE,
        trade_date          trades.trade_date%TYPE,
        instrument_id       trades.instrument_id%TYPE,
        counterparty_id     trades.counterparty_id%TYPE,
        account_id          trades.account_id%TYPE,
        side                trades.side%TYPE,
        quantity            trades.quantity%TYPE,
        price               trades.price%TYPE,
        currency            trades.currency%TYPE,
        gross_amount        trades.gross_amount%TYPE,
        commission          trades.commission%TYPE,
        venue_mic           trades.venue_mic%TYPE,
        executed_at         trades.executed_at%TYPE
    );
    TYPE t_trade_tab IS TABLE OF t_trade_row INDEX BY PLS_INTEGER;


    ---------------------------------------------------------------------------
    -- rebind_external_table
    --
    -- Points EXT_TRADES at a specific CSV. Dynamic SQL because a table name
    -- and a file name cannot be bind variables.
    ---------------------------------------------------------------------------
    PROCEDURE rebind_external_table (p_table VARCHAR2, p_filename VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ' || p_table ||
                          ' LOCATION (''' || p_filename || ''')';
    END rebind_external_table;


    ---------------------------------------------------------------------------
    -- load_trades
    ---------------------------------------------------------------------------
    FUNCTION load_trades (
        p_filename    IN VARCHAR2,
        p_chunk_size  IN PLS_INTEGER DEFAULT 5000
    ) RETURN NUMBER IS
        v_batch_id        NUMBER;
        v_buf             t_trade_tab;
        v_total_processed NUMBER := 0;
        v_total_rejected  NUMBER := 0;
        v_chunk_no        NUMBER := 0;

        CURSOR c_ext IS
            SELECT external_trade_ref, source_system, trade_date,
                   instrument_id, counterparty_id, account_id, side, quantity,
                   price, currency, gross_amount, commission,
                   venue_mic, executed_at
              FROM ext_trades;
    BEGIN
        v_batch_id := pkg_ops.begin_batch(
            p_batch_name      => 'INGEST_TRADES:' || p_filename,
            p_batch_type      => 'INGEST_OPTIMIZED',
            p_parameters_json => '{"file":"' || p_filename ||
                                 '","chunk_size":' || p_chunk_size || '}'
        );

        rebind_external_table('ext_trades', p_filename);

        OPEN c_ext;
        LOOP
            FETCH c_ext BULK COLLECT INTO v_buf LIMIT p_chunk_size;
            EXIT WHEN v_buf.COUNT = 0;
            v_chunk_no := v_chunk_no + 1;

            BEGIN
                -- One array-bound INSERT for the whole chunk. settlement_date
                -- and net_amount are left NULL; processed defaults to 'N'.
                FORALL i IN 1 .. v_buf.COUNT SAVE EXCEPTIONS
                    INSERT INTO trades (
                        trade_id, external_trade_ref, source_system, trade_date,
                        instrument_id, counterparty_id, account_id, side,
                        quantity, price, currency, gross_amount, commission,
                        venue_mic, executed_at
                    ) VALUES (
                        seq_trade_id.NEXTVAL, v_buf(i).external_trade_ref,
                        v_buf(i).source_system, v_buf(i).trade_date,
                        v_buf(i).instrument_id, v_buf(i).counterparty_id,
                        v_buf(i).account_id, v_buf(i).side, v_buf(i).quantity,
                        v_buf(i).price, v_buf(i).currency, v_buf(i).gross_amount,
                        v_buf(i).commission, v_buf(i).venue_mic,
                        v_buf(i).executed_at
                    );
                v_total_processed := v_total_processed + v_buf.COUNT;
            EXCEPTION
                WHEN OTHERS THEN
                    -- SQL%BULK_EXCEPTIONS holds one entry per failed row.
                    DECLARE
                        v_failures  PLS_INTEGER := SQL%BULK_EXCEPTIONS.COUNT;
                        v_row_idx   PLS_INTEGER;
                        v_succeeded PLS_INTEGER;
                    BEGIN
                        v_succeeded       := v_buf.COUNT - v_failures;
                        v_total_processed := v_total_processed + v_succeeded;
                        v_total_rejected  := v_total_rejected  + v_failures;

                        FOR j IN 1 .. v_failures LOOP
                            v_row_idx := SQL%BULK_EXCEPTIONS(j).ERROR_INDEX;
                            pkg_ops.log_ingest_error(
                                p_batch_id      => v_batch_id,
                                p_source_system => v_buf(v_row_idx).source_system,
                                p_external_ref  => v_buf(v_row_idx).external_trade_ref,
                                p_oracle_code   => SQL%BULK_EXCEPTIONS(j).ERROR_CODE,
                                p_error_message => SQLERRM(-SQL%BULK_EXCEPTIONS(j).ERROR_CODE),
                                p_row_payload   => v_buf(v_row_idx).source_system || '|' ||
                                                   v_buf(v_row_idx).external_trade_ref || '|' ||
                                                   v_buf(v_row_idx).trade_date
                            );
                        END LOOP;
                    END;
            END;

            COMMIT;
            DBMS_APPLICATION_INFO.SET_CLIENT_INFO(
                'batch_id=' || v_batch_id || ' chunk=' || v_chunk_no ||
                ' processed=' || v_total_processed ||
                ' rejected=' || v_total_rejected
            );
        END LOOP;
        CLOSE c_ext;

        pkg_ops.end_batch(
            p_batch_id       => v_batch_id,
            p_status         => CASE WHEN v_total_rejected = 0 THEN 'SUCCESS'
                                     WHEN v_total_processed = 0 THEN 'FAILED'
                                     ELSE 'PARTIAL' END,
            p_rows_processed => v_total_processed,
            p_rows_rejected  => v_total_rejected
        );
        RETURN v_batch_id;

    EXCEPTION
        WHEN OTHERS THEN
            pkg_ops.log_error('PKG_INGEST_OPTIMIZED',
                              'load_trades(' || p_filename || ')',
                              SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            pkg_ops.end_batch(v_batch_id, 'FAILED', v_total_processed,
                              v_total_rejected, SQLERRM);
            RAISE;
    END load_trades;

END pkg_ingest_optimized;
/
