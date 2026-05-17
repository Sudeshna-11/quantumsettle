/*
===============================================================================
DDL: Materialized view log on TRADES
===============================================================================
Purpose:
    Required by MV_DAILY_PNL, which uses REFRESH FAST. The log records every
    row-level change on TRADES so the materialized view can apply just the
    delta on each commit instead of rebuilding from scratch.

Overview:
    For a fast-refreshable aggregate materialized view the log must be created:
        - WITH ROWID, SEQUENCE   (ROWID identifies the row; SEQUENCE orders the
                                  changes so they replay correctly)
        - INCLUDING NEW VALUES   (capture the post-image so an UPDATE can be
                                  applied, not just an INSERT or DELETE)
        - listing every column the materialized view references

    CREATE MATERIALIZED VIEW LOG has no IF NOT EXISTS, so the block below drops
    an existing log first to keep this script re-runnable.
===============================================================================
*/


DECLARE
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM user_mview_logs WHERE master = 'TRADES';
    IF v_count > 0 THEN
        EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW LOG ON trades';
    END IF;
END;
/

CREATE MATERIALIZED VIEW LOG ON trades
    WITH ROWID, SEQUENCE (
        trade_date, account_id, currency, side,
        quantity, gross_amount, net_amount, commission
    )
    INCLUDING NEW VALUES
/
