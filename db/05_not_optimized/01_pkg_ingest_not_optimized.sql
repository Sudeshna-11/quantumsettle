/*
===============================================================================
Package: PKG_INGEST_NOT_OPTIMIZED
Phase:   1 of 3 — Ingest
Version: Not Optimized
===============================================================================
Purpose:
    Loads the same staged CSV into TRADES as PKG_INGEST_OPTIMIZED, and produces
    exactly the same rows — but using the slow, row-at-a-time approach. It
    exists only so the benchmark has a baseline to compare against.

Not-optimized choices (deliberate):
    - Cursor FOR loop: fetches and processes one row at a time, no BULK COLLECT.
    - One INSERT statement per row: every row pays its own PL/SQL-to-SQL
      context switch, instead of one switch per 5,000-row chunk.
    - No SAVE EXCEPTIONS: a single bad row aborts the whole load.

What this is NOT:
    This is not how you should write an ingestion routine. The optimized
    package is the intended approach. This file is a teaching baseline.

Compare with:
    PKG_INGEST_OPTIMIZED — same result via BULK COLLECT + FORALL.

Usage:
    v_batch_id := pkg_ingest_not_optimized.load_trades('trades_2026.csv');
===============================================================================
*/


CREATE OR REPLACE PACKAGE pkg_ingest_not_optimized AS

    FUNCTION load_trades (p_filename IN VARCHAR2) RETURN NUMBER;

END pkg_ingest_not_optimized;
/


CREATE OR REPLACE PACKAGE BODY pkg_ingest_not_optimized AS

    FUNCTION load_trades (p_filename IN VARCHAR2) RETURN NUMBER IS
        v_batch_id NUMBER;
        v_inserted NUMBER := 0;
    BEGIN
        v_batch_id := pkg_ops.begin_batch(
            p_batch_name      => 'INGEST_TRADES:' || p_filename,
            p_batch_type      => 'INGEST_NOT_OPTIMIZED',
            p_parameters_json => '{"file":"' || p_filename || '"}'
        );

        EXECUTE IMMEDIATE 'ALTER TABLE ext_trades LOCATION (''' || p_filename || ''')';

        -- Row-at-a-time: one fetch, one INSERT, per trade.
        FOR r IN (SELECT external_trade_ref, source_system, trade_date,
                         instrument_id, counterparty_id, account_id, side,
                         quantity, price, currency, gross_amount, commission,
                         venue_mic, executed_at
                    FROM ext_trades) LOOP

            INSERT INTO trades (
                trade_id, external_trade_ref, source_system, trade_date,
                instrument_id, counterparty_id, account_id, side,
                quantity, price, currency, gross_amount, commission,
                venue_mic, executed_at
            ) VALUES (
                seq_trade_id.NEXTVAL, r.external_trade_ref, r.source_system,
                r.trade_date, r.instrument_id, r.counterparty_id, r.account_id,
                r.side, r.quantity, r.price, r.currency, r.gross_amount,
                r.commission, r.venue_mic, r.executed_at
            );
            v_inserted := v_inserted + 1;

        END LOOP;

        COMMIT;
        pkg_ops.end_batch(v_batch_id, 'SUCCESS', v_inserted, 0);
        RETURN v_batch_id;

    EXCEPTION
        WHEN OTHERS THEN
            pkg_ops.log_error('PKG_INGEST_NOT_OPTIMIZED', 'load_trades',
                              SQLCODE, SQLERRM,
                              DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            pkg_ops.end_batch(v_batch_id, 'FAILED', v_inserted, 0, SQLERRM);
            RAISE;
    END load_trades;

END pkg_ingest_not_optimized;
/
