/*
===============================================================================
Suite: test_pkg_process
Covers: PKG_PROCESS_OPTIMIZED.run — set-based bulk enrichment
===============================================================================
Purpose:
    Verifies that the Process phase correctly derives settlement_date and
    net_amount and flips processed from 'N' to 'Y' for every trade on a date.
    Also verifies the optimized and not-optimized variants produce identical
    results.
===============================================================================
*/


CREATE OR REPLACE PACKAGE test_pkg_process AS
    PROCEDURE setup;
    PROCEDURE teardown;

    PROCEDURE test_processes_all_unprocessed_trades;
    PROCEDURE test_derives_net_amount_correctly;
    PROCEDURE test_optimized_and_not_optimized_match;
END test_pkg_process;
/


CREATE OR REPLACE PACKAGE BODY test_pkg_process AS

    c_test_date_a CONSTANT DATE := DATE '2099-01-15';
    c_test_date_b CONSTANT DATE := DATE '2099-01-16';

    PROCEDURE setup IS
    BEGIN
        pkg_test_util.reset_test_data;
    END setup;

    PROCEDURE teardown IS
    BEGIN
        pkg_test_util.reset_test_data;
    END teardown;

    ---------------------------------------------------------------------------
    -- Every unprocessed trade for a date should flip to processed='Y'.
    ---------------------------------------------------------------------------
    PROCEDURE test_processes_all_unprocessed_trades IS
        v_dummy        NUMBER;
        v_unprocessed  NUMBER;
        v_total        NUMBER;
    BEGIN
        setup;
        pkg_test_util.seed_trades(c_test_date_a, 100);

        v_dummy := pkg_process_optimized.run(c_test_date_a);

        SELECT COUNT(*) INTO v_total
          FROM trades
         WHERE source_system = 'TEST' AND trade_date = c_test_date_a;

        SELECT COUNT(*) INTO v_unprocessed
          FROM trades
         WHERE source_system = 'TEST' AND trade_date = c_test_date_a
           AND processed = 'N';

        pkg_test_util.assert_equal(
            'all seeded trades should exist', v_total, 100);
        pkg_test_util.assert_equal(
            'no trade should remain unprocessed', v_unprocessed, 0);

        teardown;
    END test_processes_all_unprocessed_trades;

    ---------------------------------------------------------------------------
    -- net_amount derivation: BUY = gross + commission, SELL = gross - commission.
    -- The seed uses gross=5000, commission=2.50, so BUY rows => 5002.50 and
    -- SELL rows => 4997.50. settlement_date must be trade_date + 2 .. 4 days
    -- (the +2 base, plus up to +2 of weekend roll).
    ---------------------------------------------------------------------------
    PROCEDURE test_derives_net_amount_correctly IS
        v_dummy        NUMBER;
        v_buy_net      NUMBER;
        v_sell_net     NUMBER;
        v_settle       DATE;
        v_settle_delta NUMBER;
    BEGIN
        setup;
        pkg_test_util.seed_trades(c_test_date_a, 10);

        v_dummy := pkg_process_optimized.run(c_test_date_a);

        SELECT MIN(net_amount) INTO v_sell_net
          FROM trades
         WHERE source_system='TEST' AND trade_date=c_test_date_a AND side='SELL';
        SELECT MIN(net_amount) INTO v_buy_net
          FROM trades
         WHERE source_system='TEST' AND trade_date=c_test_date_a AND side='BUY';

        pkg_test_util.assert_equal(
            'BUY net_amount = gross + commission',  v_buy_net,  5002.50);
        pkg_test_util.assert_equal(
            'SELL net_amount = gross - commission', v_sell_net, 4997.50);

        SELECT MIN(settlement_date) INTO v_settle
          FROM trades
         WHERE source_system='TEST' AND trade_date=c_test_date_a;

        v_settle_delta := v_settle - c_test_date_a;
        pkg_test_util.assert_between(
            'settlement_date should be trade_date + 2..4 (T+2 with weekend roll)',
            v_settle_delta, 2, 4);

        teardown;
    END test_derives_net_amount_correctly;

    ---------------------------------------------------------------------------
    -- The optimized and not-optimized variants are functionally equivalent —
    -- different SQL shape, same row state when done.
    ---------------------------------------------------------------------------
    PROCEDURE test_optimized_and_not_optimized_match IS
        v_dummy            NUMBER;
        v_opt_net_sum      NUMBER;
        v_notopt_net_sum   NUMBER;
        v_opt_settle_count NUMBER;
        v_notopt_settle_count NUMBER;
    BEGIN
        setup;
        pkg_test_util.seed_trades(c_test_date_a, 50);  -- processed by OPTIMIZED
        pkg_test_util.seed_trades(c_test_date_b, 50);  -- processed by NOT_OPTIMIZED

        v_dummy := pkg_process_optimized.run(c_test_date_a);
        v_dummy := pkg_process_not_optimized.run(c_test_date_b);

        SELECT SUM(net_amount), COUNT(settlement_date)
          INTO v_opt_net_sum, v_opt_settle_count
          FROM trades
         WHERE source_system='TEST' AND trade_date=c_test_date_a;

        SELECT SUM(net_amount), COUNT(settlement_date)
          INTO v_notopt_net_sum, v_notopt_settle_count
          FROM trades
         WHERE source_system='TEST' AND trade_date=c_test_date_b;

        pkg_test_util.assert_equal(
            'optimized net_amount SUM should equal not-optimized SUM',
            v_opt_net_sum, v_notopt_net_sum);
        pkg_test_util.assert_equal(
            'both variants should set settlement_date for every row (opt)',
            v_opt_settle_count, 50);
        pkg_test_util.assert_equal(
            'both variants should set settlement_date for every row (not-opt)',
            v_notopt_settle_count, 50);

        teardown;
    END test_optimized_and_not_optimized_match;

END test_pkg_process;
/
