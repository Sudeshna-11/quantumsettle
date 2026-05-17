/*
===============================================================================
DDL: Dimension (reference) tables
===============================================================================
Purpose:
    Small, mostly-static lookup tables that the TRADES fact table references
    through foreign keys: currencies, exchanges, counterparties, accounts and
    instruments.

Overview:
    These tables are tiny compared to TRADES, so they are NOT partitioned.
    All DDL uses Oracle 23ai's CREATE ... IF NOT EXISTS, which makes this
    script safe to re-run as part of the migration step.

Notes:
    Sequences for the surrogate keys live at the bottom of this file so the
    data faker can MERGE reference rows without hard-coding IDs.
===============================================================================
*/


-------------------------------------------------------------------------------
-- currencies
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS currencies (
    currency_code   VARCHAR2(3)    NOT NULL,
    currency_name   VARCHAR2(40)   NOT NULL,
    active_flag     VARCHAR2(1)    DEFAULT 'Y' NOT NULL,

    CONSTRAINT pk_currencies        PRIMARY KEY (currency_code),
    CONSTRAINT ck_currencies_active CHECK (active_flag IN ('Y','N'))
) TABLESPACE qs_data
/


-------------------------------------------------------------------------------
-- exchanges  (MIC = Market Identifier Code, e.g. XNYS, XNAS)
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS exchanges (
    mic             VARCHAR2(4)    NOT NULL,
    exchange_name   VARCHAR2(80)   NOT NULL,
    country_iso2    VARCHAR2(2)    NOT NULL,
    timezone        VARCHAR2(40),
    active_flag     VARCHAR2(1)    DEFAULT 'Y' NOT NULL,

    CONSTRAINT pk_exchanges         PRIMARY KEY (mic),
    CONSTRAINT ck_exchanges_active  CHECK (active_flag IN ('Y','N'))
) TABLESPACE qs_data
/


-------------------------------------------------------------------------------
-- counterparties  (the brokers we trade through)
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS counterparties (
    counterparty_id     NUMBER(10)     NOT NULL,
    lei                 VARCHAR2(20),
    short_name          VARCHAR2(40)   NOT NULL,
    long_name           VARCHAR2(120)  NOT NULL,
    counterparty_type   VARCHAR2(20)   DEFAULT 'BROKER' NOT NULL,
    country_iso2        VARCHAR2(2),
    active_flag         VARCHAR2(1)    DEFAULT 'Y' NOT NULL,
    created_at          TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at          TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT pk_counterparties        PRIMARY KEY (counterparty_id),
    CONSTRAINT uk_counterparties_lei    UNIQUE (lei),
    CONSTRAINT ck_counterparties_type   CHECK (counterparty_type IN ('BROKER')),
    CONSTRAINT ck_counterparties_active CHECK (active_flag IN ('Y','N'))
) TABLESPACE qs_data
/


-------------------------------------------------------------------------------
-- accounts  (internal trading books)
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS accounts (
    account_id      NUMBER(10)     NOT NULL,
    account_code    VARCHAR2(20)   NOT NULL,
    account_name    VARCHAR2(120)  NOT NULL,
    account_type    VARCHAR2(20)   DEFAULT 'TRADING' NOT NULL,
    desk            VARCHAR2(40),
    book            VARCHAR2(40),
    base_currency   VARCHAR2(3)    NOT NULL,
    active_flag     VARCHAR2(1)    DEFAULT 'Y' NOT NULL,
    created_at      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT pk_accounts          PRIMARY KEY (account_id),
    CONSTRAINT uk_accounts_code     UNIQUE (account_code),
    CONSTRAINT ck_accounts_type     CHECK (account_type IN ('TRADING')),
    CONSTRAINT ck_accounts_active   CHECK (active_flag IN ('Y','N'))
) TABLESPACE qs_data
/


-------------------------------------------------------------------------------
-- instruments  (securities master)
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS instruments (
    instrument_id   NUMBER(10)     NOT NULL,
    symbol          VARCHAR2(12)   NOT NULL,
    cusip           VARCHAR2(9),
    isin            VARCHAR2(12),
    figi            VARCHAR2(12),
    primary_mic     VARCHAR2(4),
    instrument_type VARCHAR2(20)   NOT NULL,
    currency        VARCHAR2(3)    NOT NULL,
    country_iso2    VARCHAR2(2),
    lot_size        NUMBER(10)     DEFAULT 1    NOT NULL,
    tick_size       NUMBER(10,6)   DEFAULT 0.01 NOT NULL,
    active_flag     VARCHAR2(1)    DEFAULT 'Y'  NOT NULL,
    listed_date     DATE,
    created_at      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT pk_instruments        PRIMARY KEY (instrument_id),
    CONSTRAINT uk_instruments_symbol UNIQUE (symbol),
    CONSTRAINT uk_instruments_isin   UNIQUE (isin),
    CONSTRAINT ck_instruments_type   CHECK (instrument_type IN ('EQUITY','ETF')),
    CONSTRAINT ck_instruments_active CHECK (active_flag IN ('Y','N'))
) TABLESPACE qs_data
/

CREATE INDEX IF NOT EXISTS ix_instruments_symbol
    ON instruments (symbol, active_flag) TABLESPACE qs_index
/


-------------------------------------------------------------------------------
-- surrogate-key sequences
-------------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS seq_counterparty_id START WITH 1000 INCREMENT BY 1 NOCACHE
/
CREATE SEQUENCE IF NOT EXISTS seq_account_id      START WITH 1000 INCREMENT BY 1 NOCACHE
/
CREATE SEQUENCE IF NOT EXISTS seq_instrument_id   START WITH 1000 INCREMENT BY 1 NOCACHE
/
