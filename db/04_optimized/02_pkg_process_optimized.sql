/*
===============================================================================
Package: PKG_PROCESS_OPTIMIZED
Phase:   2 of 3 — Process
Version: Optimized
===============================================================================
Purpose:
    Enriches freshly-ingested trades. For every not-yet-processed trade on a
    given date it derives two columns and flips the processed flag:
        - settlement_date  = trade_date + 2 business days (T+2, weekend-rolled)
        - net_amount       = gross_amount adjusted for commission and side
        - processed        = 'Y'

Overview:
    The whole day is handled by ONE set-based UPDATE statement. The WHERE
    clause filters on trade_date, the table's partition key, so Oracle prunes
    to a single monthly partition instead of scanning the table.

Optimization techniques:
    - Set-based UPDATE: one statement updates every row for the date; no
      per-row PL/SQL loop, no per-row context switch.
    - Partition pruning: WHERE trade_date = :d lets the planner touch exactly
      one partition. This is the single biggest win in the project — confirmed
      by the EXPLAIN PLAN in docs/perf-story.md (PARTITION RANGE SINGLE).

Compare with:
    PKG_PROCESS_NOT_OPTIMIZED — same result, row-by-row cursor loop, and a
    WHERE clause that locates rows by trade_id alone so the planner cannot
    prune (PARTITION RANGE ALL).

Usage:
    v_batch_id := pkg_process_optimized.run(DATE '2026-05-12');
    pkg_process_optimized.run_all_pending;
===============================================================================
*/


CREATE OR REPLACE PACKAGE pkg_process_optimized AS

    /* Enrich every unprocessed trade for one trade_date. Returns batch_id. */
    FUNCTION run (p_trade_date IN DATE) RETURN NUMBER;

    /* Run every trade_date that still has unprocessed trades. */
    PROCEDURE run_all_pending;

END pkg_process_optimized;
/


CREATE OR REPLACE PACKAGE BODY pkg_process_optimized AS

    ---------------------------------------------------------------------------
    -- run
    ---------------------------------------------------------------------------
    FUNCTION run (p_trade_date IN DATE) RETURN NUMBER IS
        v_batch_id NUMBER;
        v_updated  NUMBER := 0;
    BEGIN
        v_batch_id := pkg_ops.begin_batch(
            p_batch_name      => 'PROCESS:' || TO_CHAR(p_trade_date, 'YYYY-MM-DD'),
            p_batch_type      => 'PROCESS_OPTIMIZED',
            p_parameters_json => '{"trade_date":"' ||
                                 TO_CHAR(p_trade_date, 'YYYY-MM-DD') || '"}'
        );

        -- One set-based statement for the whole day. The trade_date predicate
        -- prunes execution to a single partition.
        UPDATE trades t
           SET t.settlement_date = CASE TO_CHAR(t.trade_date + 2, 'DY',
                                                'NLS_DATE_LANGUAGE=ENGLISH')
                                       WHEN 'SAT' THEN t.trade_date + 4
                                       WHEN 'SUN' THEN t.trade_date + 3
                                       ELSE t.trade_date + 2
                                   END,
               t.net_amount      = CASE t.side
                                       WHEN 'BUY'  THEN t.gross_amount + t.commission
                                       ELSE             t.gross_amount - t.commission
                                   END,
               t.processed       = 'Y',
               t.updated_at      = SYSTIMESTAMP
         WHERE t.trade_date = p_trade_date
           AND t.processed  = 'N';
        v_updated := SQL%ROWCOUNT;

        COMMIT;

        pkg_ops.end_batch(
            p_batch_id       => v_batch_id,
            p_status         => 'SUCCESS',
            p_rows_processed => v_updated
        );
        RETURN v_batch_id;

    EXCEPTION
        WHEN OTHERS THEN
            pkg_ops.log_error('PKG_PROCESS_OPTIMIZED',
                              'run(' || TO_CHAR(p_trade_date, 'YYYY-MM-DD') || ')',
                              SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            pkg_ops.end_batch(v_batch_id, 'FAILED', v_updated, 0, SQLERRM);
            RAISE;
    END run;

    ---------------------------------------------------------------------------
    -- run_all_pending
    ---------------------------------------------------------------------------
    PROCEDURE run_all_pending IS
        v_count NUMBER := 0;
        v_dummy NUMBER;
    BEGIN
        FOR r IN (SELECT DISTINCT trade_date
                    FROM trades
                   WHERE processed = 'N'
                   ORDER BY trade_date) LOOP
            v_dummy := run(r.trade_date);
            v_count := v_count + 1;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('Processed ' || v_count || ' trade date(s).');
    END run_all_pending;

END pkg_process_optimized;
/
