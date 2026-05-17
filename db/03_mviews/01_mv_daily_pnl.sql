/*
===============================================================================
DDL: MV_DAILY_PNL — pre-aggregated daily P&L
===============================================================================
Purpose:
    A materialized view that keeps the daily-P&L aggregation
    (trade_date, account, currency, side) permanently up to date, so the
    Report phase never pays the GROUP BY at query time.

Overview:
    REFRESH FAST ON COMMIT — every commit on TRADES triggers an incremental
    maintenance pass that applies just the delta recorded in the MV log.

    For a fast-refreshable aggregate MV, Oracle requires COUNT(*) plus a
    COUNT(c) alongside every SUM(c); that is why each measure below appears as
    a SUM/COUNT pair.

    ENABLE QUERY REWRITE lets the optimizer transparently substitute this MV
    into any base-table query of a compatible shape.

Used by:
    PKG_REPORT_OPTIMIZED.get_daily_pnl
===============================================================================
*/


DECLARE
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count
      FROM user_mviews WHERE mview_name = 'MV_DAILY_PNL';
    IF v_count > 0 THEN
        EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW mv_daily_pnl';
    END IF;
END;
/

CREATE MATERIALIZED VIEW mv_daily_pnl
    TABLESPACE qs_data
    BUILD IMMEDIATE
    REFRESH FAST ON COMMIT
    ENABLE QUERY REWRITE
AS
SELECT trade_date,
       account_id,
       currency,
       side,
       COUNT(*)          AS trade_count,
       SUM(quantity)     AS sum_quantity,     COUNT(quantity)     AS cnt_quantity,
       SUM(gross_amount) AS sum_gross_amount, COUNT(gross_amount) AS cnt_gross_amount,
       SUM(net_amount)   AS sum_net_amount,   COUNT(net_amount)   AS cnt_net_amount,
       SUM(commission)   AS sum_commission,   COUNT(commission)   AS cnt_commission
  FROM trades
 GROUP BY trade_date, account_id, currency, side
/
