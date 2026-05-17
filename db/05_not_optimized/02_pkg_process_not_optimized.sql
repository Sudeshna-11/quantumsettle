/*
===============================================================================
Package: PKG_PROCESS_NOT_OPTIMIZED
Phase:   2 of 3 — Process
Version: Not Optimized
===============================================================================
Purpose:
    Enriches ingested trades exactly like PKG_PROCESS_OPTIMIZED — derives
    settlement_date and net_amount, sets processed = 'Y' — and produces an
    identical end state. It just gets there the slow way.

Not-optimized choices (deliberate):
    - Cursor FOR loop: one trade at a time instead of a single set-based
      UPDATE for the whole day.
    - One UPDATE statement per trade: a context switch per row.
    - WHERE trade_id = :id ONLY: the UPDATE locates each row by trade_id with
      no trade_date predicate. There is no global index on trade_id (only the
      LOCAL partition-key index), so the planner CANNOT prune — it probes
      every partition on every UPDATE. This is the costly difference.

What this is NOT:
    Not how to write a bulk transform. Set-based UPDATE with a partition-key
    predicate (the optimized package) is the intended approach.

Compare with:
    PKG_PROCESS_OPTIMIZED — one set-based UPDATE, partition-pruned. See
    docs/perf-story.md for the side-by-side EXPLAIN PLAN.

Usage:
    v_batch_id := pkg_process_not_optimized.run(DATE '2026-05-12');
===============================================================================
*/


CREATE OR REPLACE PACKAGE pkg_process_not_optimized AS

    FUNCTION run (p_trade_date IN DATE) RETURN NUMBER;

    PROCEDURE run_all_pending;

END pkg_process_not_optimized;
/


CREATE OR REPLACE PACKAGE BODY pkg_process_not_optimized AS

    ---------------------------------------------------------------------------
    -- run
    ---------------------------------------------------------------------------
    FUNCTION run (p_trade_date IN DATE) RETURN NUMBER IS
        v_batch_id        NUMBER;
        v_updated         NUMBER := 0;
        v_settlement_date DATE;
        v_net_amount      trades.net_amount%TYPE;
    BEGIN
        v_batch_id := pkg_ops.begin_batch(
            p_batch_name      => 'PROCESS:' || TO_CHAR(p_trade_date, 'YYYY-MM-DD'),
            p_batch_type      => 'PROCESS_NOT_OPTIMIZED',
            p_parameters_json => '{"trade_date":"' ||
                                 TO_CHAR(p_trade_date, 'YYYY-MM-DD') || '"}'
        );

        -- Row-at-a-time. Each iteration derives the values in PL/SQL, then
        -- issues a single-row UPDATE located by trade_id alone.
        FOR r IN (SELECT trade_id, trade_date, side, gross_amount, commission
                    FROM trades
                   WHERE trade_date = p_trade_date
                     AND processed  = 'N') LOOP

            v_settlement_date :=
                CASE TO_CHAR(r.trade_date + 2, 'DY', 'NLS_DATE_LANGUAGE=ENGLISH')
                    WHEN 'SAT' THEN r.trade_date + 4
                    WHEN 'SUN' THEN r.trade_date + 3
                    ELSE r.trade_date + 2
                END;

            v_net_amount :=
                CASE r.side
                    WHEN 'BUY'  THEN r.gross_amount + r.commission
                    ELSE             r.gross_amount - r.commission
                END;

            -- No trade_date in the WHERE clause -> no partition pruning.
            UPDATE trades
               SET settlement_date = v_settlement_date,
                   net_amount      = v_net_amount,
                   processed       = 'Y',
                   updated_at      = SYSTIMESTAMP
             WHERE trade_id = r.trade_id;

            v_updated := v_updated + 1;

        END LOOP;

        COMMIT;

        pkg_ops.end_batch(
            p_batch_id       => v_batch_id,
            p_status         => 'SUCCESS',
            p_rows_processed => v_updated
        );
        RETURN v_batch_id;

    EXCEPTION
        WHEN OTHERS THEN
            pkg_ops.log_error('PKG_PROCESS_NOT_OPTIMIZED',
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

END pkg_process_not_optimized;
/
