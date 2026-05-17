/*
===============================================================================
Package: PKG_REPORT_NOT_OPTIMIZED
Phase:   3 of 3 — Report
Version: Not Optimized
===============================================================================
Purpose:
    Produces the same daily P&L numbers as PKG_REPORT_OPTIMIZED — but recomputes
    the whole aggregation against the TRADES base table on every single call.

Not-optimized choices (deliberate):
    - No materialized view: the GROUP BY over the trade_date partition runs in
      full every time the report is requested.
    - NO_REWRITE hint: even though MV_DAILY_PNL exists and could satisfy this
      query, the hint forces the optimizer to go to the base table — so the
      benchmark measures the genuine "no MV" cost.

What this is NOT:
    Not how you serve a frequently-requested report. Pre-aggregate with a
    materialized view (the optimized package) when the same summary is read
    over and over.

Compare with:
    PKG_REPORT_OPTIMIZED — reads the pre-aggregated MV_DAILY_PNL.

Usage:
    rc := pkg_report_not_optimized.get_daily_pnl(DATE '2026-05-12');
===============================================================================
*/


CREATE OR REPLACE PACKAGE pkg_report_not_optimized AS

    FUNCTION get_daily_pnl (
        p_business_date  IN DATE,
        p_account_id     IN NUMBER DEFAULT NULL
    ) RETURN SYS_REFCURSOR;

END pkg_report_not_optimized;
/


CREATE OR REPLACE PACKAGE BODY pkg_report_not_optimized AS

    ---------------------------------------------------------------------------
    -- get_daily_pnl
    --
    -- Full GROUP BY against the TRADES base table. The NO_REWRITE hint stops
    -- the optimizer from quietly substituting MV_DAILY_PNL — this package is
    -- meant to show what life is like without the materialized view.
    ---------------------------------------------------------------------------
    FUNCTION get_daily_pnl (
        p_business_date  IN DATE,
        p_account_id     IN NUMBER DEFAULT NULL
    ) RETURN SYS_REFCURSOR IS
        rc SYS_REFCURSOR;
    BEGIN
        OPEN rc FOR
            SELECT /*+ NO_REWRITE */
                   trade_date,
                   account_id,
                   currency,
                   COUNT(*)                                              AS total_trade_count,
                   SUM(CASE side WHEN 'BUY' THEN  quantity
                                 ELSE -quantity END)                     AS net_quantity,
                   SUM(gross_amount)                                     AS gross_volume,
                   SUM(CASE side WHEN 'BUY' THEN -net_amount
                                 ELSE  net_amount END)                   AS net_pnl,
                   SUM(commission)                                       AS total_commission
              FROM trades
             WHERE trade_date = p_business_date
               AND (p_account_id IS NULL OR account_id = p_account_id)
             GROUP BY trade_date, account_id, currency
             ORDER BY account_id, currency;
        RETURN rc;
    END get_daily_pnl;

END pkg_report_not_optimized;
/
