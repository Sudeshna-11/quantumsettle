/*
===============================================================================
Package: PKG_REPORT_OPTIMIZED
Phase:   3 of 3 — Report
Version: Optimized
===============================================================================
Purpose:
    Answers the daily P&L question: for a given trade date, what is each
    account's net position, traded volume and net P&L?

Overview:
    The aggregation is pre-computed and kept current by the MV_DAILY_PNL
    materialized view (REFRESH FAST ON COMMIT). This package just reads from
    the materialized view, so the heavy GROUP BY over the TRADES partition is
    never paid at query time.

Optimization techniques:
    - Materialized view: the (trade_date, account, currency, side) aggregation
      is maintained incrementally on every commit. The report query reads a
      handful of pre-summarised rows.
    - Query rewrite enabled: even a base-table query in the right shape would
      be transparently rewritten by the optimizer to use the MV.

Compare with:
    PKG_REPORT_NOT_OPTIMIZED — same numbers, but re-runs the full GROUP BY
    against the TRADES base table on every call (NO_REWRITE forced).

Functions return SYS_REFCURSOR so the Python dashboard and CLI can stream
rows instead of buffering them.

Usage:
    rc := pkg_report_optimized.get_daily_pnl(DATE '2026-05-12');
===============================================================================
*/


CREATE OR REPLACE PACKAGE pkg_report_optimized AS

    /* Daily P&L per account/currency for a trade date. account_id optional. */
    FUNCTION get_daily_pnl (
        p_business_date  IN DATE,
        p_account_id     IN NUMBER DEFAULT NULL
    ) RETURN SYS_REFCURSOR;

    /* Processed vs not-yet-processed trade counts for a trade date. */
    FUNCTION get_processing_status (
        p_business_date  IN DATE
    ) RETURN SYS_REFCURSOR;

    /* Force a refresh of MV_DAILY_PNL (it is fast-refresh-on-commit anyway). */
    PROCEDURE refresh;

END pkg_report_optimized;
/


CREATE OR REPLACE PACKAGE BODY pkg_report_optimized AS

    ---------------------------------------------------------------------------
    -- get_daily_pnl
    --
    -- Reads the pre-aggregated MV. The CASE-on-side lives in an inner derived
    -- table so the outer SUMs only see scalar columns — a direct
    -- SUM(CASE side ...) against the MV raises ORA-00935 because `side` is in
    -- the MV's GROUP BY but not the outer query's.
    ---------------------------------------------------------------------------
    FUNCTION get_daily_pnl (
        p_business_date  IN DATE,
        p_account_id     IN NUMBER DEFAULT NULL
    ) RETURN SYS_REFCURSOR IS
        rc SYS_REFCURSOR;
    BEGIN
        OPEN rc FOR
            SELECT trade_date,
                   account_id,
                   currency,
                   SUM(trade_count_in)    AS total_trade_count,
                   SUM(signed_quantity)   AS net_quantity,
                   SUM(gross_amount_in)   AS gross_volume,
                   SUM(signed_net_amount) AS net_pnl,
                   SUM(commission_in)     AS total_commission
              FROM (
                   SELECT trade_date,
                          account_id,
                          currency,
                          trade_count      AS trade_count_in,
                          sum_gross_amount AS gross_amount_in,
                          sum_commission   AS commission_in,
                          CASE side WHEN 'BUY' THEN  sum_quantity
                                    ELSE -sum_quantity END   AS signed_quantity,
                          CASE side WHEN 'BUY' THEN -sum_net_amount
                                    ELSE  sum_net_amount END AS signed_net_amount
                     FROM mv_daily_pnl
                    WHERE trade_date = p_business_date
                      AND (p_account_id IS NULL OR account_id = p_account_id)
                   )
             GROUP BY trade_date, account_id, currency
             ORDER BY account_id, currency;
        RETURN rc;
    END get_daily_pnl;

    ---------------------------------------------------------------------------
    -- get_processing_status
    ---------------------------------------------------------------------------
    FUNCTION get_processing_status (
        p_business_date  IN DATE
    ) RETURN SYS_REFCURSOR IS
        rc SYS_REFCURSOR;
    BEGIN
        OPEN rc FOR
            SELECT processed,
                   CASE processed WHEN 'Y' THEN 'Processed'
                                  ELSE 'Not yet processed' END AS status_label,
                   COUNT(*) AS trade_count
              FROM trades
             WHERE trade_date = p_business_date
             GROUP BY processed
             ORDER BY processed DESC;
        RETURN rc;
    END get_processing_status;

    ---------------------------------------------------------------------------
    -- refresh
    ---------------------------------------------------------------------------
    PROCEDURE refresh IS
    BEGIN
        DBMS_MVIEW.REFRESH('MV_DAILY_PNL', 'F');
    END refresh;

END pkg_report_optimized;
/
