/*
===============================================================================
Suite: test_pkg_report
Covers: PKG_REPORT_OPTIMIZED.get_daily_pnl vs PKG_REPORT_NOT_OPTIMIZED.get_daily_pnl
===============================================================================
Purpose:
    Verifies that the optimized (MV-backed) and not-optimized (base-table)
    daily-P&L reports return identical row counts and totals for the same
    inputs. Different SQL shape, same numbers.
===============================================================================
*/


CREATE OR REPLACE PACKAGE test_pkg_report AS
    PROCEDURE setup;
    PROCEDURE teardown;

    PROCEDURE test_optimized_and_not_optimized_return_same_pnl;
END test_pkg_report;
/


CREATE OR REPLACE PACKAGE BODY test_pkg_report AS

    c_test_date CONSTANT DATE := DATE '2099-02-10';

    PROCEDURE setup IS
    BEGIN
        pkg_test_util.reset_test_data;
    END setup;

    PROCEDURE teardown IS
    BEGIN
        pkg_test_util.reset_test_data;
    END teardown;

    ---------------------------------------------------------------------------
    -- Materialise both ref cursors and compare the aggregates.
    ---------------------------------------------------------------------------
    PROCEDURE test_optimized_and_not_optimized_return_same_pnl IS
        v_dummy           NUMBER;
        v_opt_rc          SYS_REFCURSOR;
        v_notopt_rc       SYS_REFCURSOR;

        v_opt_total       NUMBER := 0;
        v_opt_net_pnl     NUMBER := 0;
        v_opt_rows        NUMBER := 0;
        v_notopt_total    NUMBER := 0;
        v_notopt_net_pnl  NUMBER := 0;
        v_notopt_rows     NUMBER := 0;

        v_td  DATE;       v_acc  NUMBER;    v_ccy VARCHAR2(3);
        v_tc  NUMBER;     v_nq   NUMBER;    v_gv  NUMBER;
        v_np  NUMBER;     v_tcom NUMBER;
    BEGIN
        setup;
        pkg_test_util.seed_trades(c_test_date, 30);
        v_dummy := pkg_process_optimized.run(c_test_date);

        -- A commit is needed so MV_DAILY_PNL's fast-refresh-on-commit fires.
        COMMIT;

        v_opt_rc    := pkg_report_optimized.get_daily_pnl(c_test_date);
        v_notopt_rc := pkg_report_not_optimized.get_daily_pnl(c_test_date);

        LOOP
            FETCH v_opt_rc INTO v_td, v_acc, v_ccy, v_tc, v_nq, v_gv, v_np, v_tcom;
            EXIT WHEN v_opt_rc%NOTFOUND;
            v_opt_total   := v_opt_total + v_tc;
            v_opt_net_pnl := v_opt_net_pnl + NVL(v_np, 0);
            v_opt_rows    := v_opt_rows + 1;
        END LOOP;
        CLOSE v_opt_rc;

        LOOP
            FETCH v_notopt_rc INTO v_td, v_acc, v_ccy, v_tc, v_nq, v_gv, v_np, v_tcom;
            EXIT WHEN v_notopt_rc%NOTFOUND;
            v_notopt_total   := v_notopt_total + v_tc;
            v_notopt_net_pnl := v_notopt_net_pnl + NVL(v_np, 0);
            v_notopt_rows    := v_notopt_rows + 1;
        END LOOP;
        CLOSE v_notopt_rc;

        pkg_test_util.assert_equal(
            'both reports should return same row count',
            v_opt_rows, v_notopt_rows);
        pkg_test_util.assert_equal(
            'both reports should report 30 trades total',
            v_opt_total, 30);
        pkg_test_util.assert_equal(
            'optimized and not-optimized trade counts should match',
            v_opt_total, v_notopt_total);
        pkg_test_util.assert_equal(
            'optimized and not-optimized net P&L should match',
            v_opt_net_pnl, v_notopt_net_pnl);

        teardown;
    END test_optimized_and_not_optimized_return_same_pnl;

END test_pkg_report;
/
