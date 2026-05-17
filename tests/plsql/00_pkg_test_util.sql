/*
===============================================================================
Package: PKG_TEST_UTIL
Role:    Test-suite toolbox (assertion helpers + test-data fixtures)
===============================================================================
Purpose:
    Every test_pkg_* test procedure needs to say "I expected X, got Y" cleanly.
    This package gives them helpers — assert_equal, assert_true, assert_between,
    assert_raises — that raise ORA-20100 on failure. The Python test runner
    catches that as a FAIL instead of a PASS.

Overview:
    Style mirrors utPLSQL's ut.expect(...).to_equal(...) intent: same
    assertions, same failure semantics. Swapping to real utPLSQL later is a
    rename, not a rewrite.

    reset_test_data and seed_trades let each test set up its own deterministic
    data without colliding with real data — every test row is tagged
    source_system='TEST' and reset_test_data only deletes those.
===============================================================================
*/


CREATE OR REPLACE PACKAGE pkg_test_util AS

    PROCEDURE assert_equal   (p_label VARCHAR2, p_actual NUMBER,   p_expected NUMBER);
    PROCEDURE assert_equal   (p_label VARCHAR2, p_actual VARCHAR2, p_expected VARCHAR2);
    PROCEDURE assert_true    (p_label VARCHAR2, p_condition BOOLEAN);
    PROCEDURE assert_between (p_label VARCHAR2, p_actual NUMBER, p_lo NUMBER, p_hi NUMBER);
    PROCEDURE assert_raises  (p_label VARCHAR2, p_expected_sqlcode NUMBER);

    /* Wipe test-marked rows (source_system='TEST') from trades + ingest_errors. */
    PROCEDURE reset_test_data;

    /* Insert N synthetic raw trades on p_trade_date with processed='N'. */
    PROCEDURE seed_trades (p_trade_date IN DATE, p_count IN PLS_INTEGER);

END pkg_test_util;
/


CREATE OR REPLACE PACKAGE BODY pkg_test_util AS

    ---------------------------------------------------------------------------
    -- assertions
    ---------------------------------------------------------------------------
    PROCEDURE assert_equal (p_label VARCHAR2, p_actual NUMBER, p_expected NUMBER) IS
    BEGIN
        IF (p_actual IS NULL AND p_expected IS NULL) OR p_actual = p_expected THEN
            RETURN;
        END IF;
        RAISE_APPLICATION_ERROR(-20100,
            p_label || ' — expected ' || NVL(TO_CHAR(p_expected), '<null>')
                    || ', got ' || NVL(TO_CHAR(p_actual), '<null>'));
    END assert_equal;

    PROCEDURE assert_equal (p_label VARCHAR2, p_actual VARCHAR2, p_expected VARCHAR2) IS
    BEGIN
        IF (p_actual IS NULL AND p_expected IS NULL) OR p_actual = p_expected THEN
            RETURN;
        END IF;
        RAISE_APPLICATION_ERROR(-20100,
            p_label || ' — expected ''' || NVL(p_expected, '<null>')
                    || ''', got ''' || NVL(p_actual, '<null>') || '''');
    END assert_equal;

    PROCEDURE assert_true (p_label VARCHAR2, p_condition BOOLEAN) IS
    BEGIN
        IF p_condition THEN RETURN; END IF;
        RAISE_APPLICATION_ERROR(-20100, p_label || ' — expected TRUE, got FALSE');
    END assert_true;

    PROCEDURE assert_between (p_label VARCHAR2, p_actual NUMBER, p_lo NUMBER, p_hi NUMBER) IS
    BEGIN
        IF p_actual BETWEEN p_lo AND p_hi THEN RETURN; END IF;
        RAISE_APPLICATION_ERROR(-20100,
            p_label || ' — expected in [' || p_lo || ', ' || p_hi || '], got ' || p_actual);
    END assert_between;

    PROCEDURE assert_raises (p_label VARCHAR2, p_expected_sqlcode NUMBER) IS
    BEGIN
        IF SQLCODE = p_expected_sqlcode THEN RETURN; END IF;
        RAISE_APPLICATION_ERROR(-20100,
            p_label || ' — expected SQLCODE ' || p_expected_sqlcode || ', got ' || SQLCODE);
    END assert_raises;

    ---------------------------------------------------------------------------
    -- test-data fixtures
    ---------------------------------------------------------------------------
    PROCEDURE reset_test_data IS
    BEGIN
        DELETE FROM trades        WHERE source_system = 'TEST';
        DELETE FROM ingest_errors WHERE source_system = 'TEST';
        COMMIT;
    END reset_test_data;

    PROCEDURE seed_trades (p_trade_date IN DATE, p_count IN PLS_INTEGER) IS
        v_account_id      NUMBER;
        v_instrument_id   NUMBER;
        v_counterparty_id NUMBER;
    BEGIN
        SELECT MIN(account_id)      INTO v_account_id      FROM accounts;
        SELECT MIN(instrument_id)   INTO v_instrument_id   FROM instruments;
        SELECT MIN(counterparty_id) INTO v_counterparty_id FROM counterparties
            WHERE counterparty_type = 'BROKER';

        -- Synthetic raw trades: net_amount and settlement_date are LEFT NULL,
        -- processed defaults to 'N' — i.e., these look exactly like rows the
        -- Ingest phase would have produced. The Process phase tests rely on
        -- that.
        FOR i IN 1 .. p_count LOOP
            INSERT INTO trades (
                trade_id, external_trade_ref, source_system, trade_date,
                instrument_id, counterparty_id, account_id,
                side, quantity, price, currency, gross_amount, commission,
                venue_mic, executed_at
            ) VALUES (
                seq_trade_id.NEXTVAL,
                'TEST-' || TO_CHAR(p_trade_date,'YYYYMMDD') || '-' || LPAD(i, 6, '0'),
                'TEST', p_trade_date,
                v_instrument_id, v_counterparty_id, v_account_id,
                CASE MOD(i, 2) WHEN 0 THEN 'BUY' ELSE 'SELL' END,
                100, 50.00, 'USD', 5000.00, 2.50,
                'XNYS', CAST(p_trade_date AS TIMESTAMP)
            );
        END LOOP;
        COMMIT;
    END seed_trades;

END pkg_test_util;
/
