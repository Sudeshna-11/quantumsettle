/*
===============================================================================
DDL: Foreign key constraints
===============================================================================
Purpose:
    Adds every foreign key in one place, AFTER all tables exist, so the
    migration step is not sensitive to table-creation order.

Overview:
    CREATE TABLE ... IF NOT EXISTS makes table DDL idempotent, but
    ALTER TABLE ... ADD CONSTRAINT has no equivalent. The add_fk helper below
    wraps each ALTER in a block that swallows "already exists" style errors so
    this script is safe to re-run.
===============================================================================
*/


DECLARE
    PROCEDURE add_fk (
        p_table   VARCHAR2,
        p_name    VARCHAR2,
        p_clause  VARCHAR2
    ) IS
    BEGIN
        EXECUTE IMMEDIATE
            'ALTER TABLE ' || p_table || ' ADD CONSTRAINT ' || p_name || ' ' || p_clause;
    EXCEPTION
        WHEN OTHERS THEN
            -- 02275: matching FK already exists
            -- 02264: constraint name already in use
            -- 02261: matching unique/PK already exists
            IF SQLCODE IN (-2275, -2264, -2261) THEN
                NULL;
            ELSE
                RAISE;
            END IF;
    END;
BEGIN
    ---------------------------------------------------------------------------
    -- dimension -> dimension
    ---------------------------------------------------------------------------
    add_fk('accounts',     'fk_accounts_currency',    'FOREIGN KEY (base_currency) REFERENCES currencies (currency_code)');
    add_fk('instruments',  'fk_instruments_currency', 'FOREIGN KEY (currency)      REFERENCES currencies (currency_code)');
    add_fk('instruments',  'fk_instruments_exchange', 'FOREIGN KEY (primary_mic)   REFERENCES exchanges  (mic)');

    ---------------------------------------------------------------------------
    -- trades -> dimensions
    ---------------------------------------------------------------------------
    add_fk('trades',       'fk_trades_instrument',    'FOREIGN KEY (instrument_id)   REFERENCES instruments    (instrument_id)');
    add_fk('trades',       'fk_trades_counterparty',  'FOREIGN KEY (counterparty_id) REFERENCES counterparties (counterparty_id)');
    add_fk('trades',       'fk_trades_account',       'FOREIGN KEY (account_id)      REFERENCES accounts       (account_id)');
    add_fk('trades',       'fk_trades_currency',      'FOREIGN KEY (currency)        REFERENCES currencies     (currency_code)');
    add_fk('trades',       'fk_trades_venue',         'FOREIGN KEY (venue_mic)       REFERENCES exchanges      (mic)');

    ---------------------------------------------------------------------------
    -- observability
    ---------------------------------------------------------------------------
    add_fk('ingest_errors','fk_ingest_errors_batch',  'FOREIGN KEY (batch_id)        REFERENCES batch_audit    (batch_id)');
END;
/
