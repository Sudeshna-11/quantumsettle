/*
===============================================================================
DDL: EXT_TRADES — external table over the staged CSV feed
===============================================================================
Purpose:
    Exposes a raw trade CSV file on disk as a read-only SQL table. This is the
    source the Ingest phase reads from.

Overview:
    The QS_STAGED directory object (created by the Python admin helper, since
    CREATE DIRECTORY needs a privileged user) points at the folder where the
    data faker drops its CSV files. The LOCATION clause below names a
    placeholder file; both the Optimized and Not-Optimized ingest packages
    rebind it to the real filename at runtime with ALTER TABLE ... LOCATION.

    The column list matches the faker's CSV header exactly. Note there is NO
    settlement_date or net_amount column here — those are DERIVED later by the
    Process phase, not supplied by the feed.

    LRTRIM trims whitespace from every field so a stray carriage return from a
    Windows-written CSV cannot corrupt the last column.
===============================================================================
*/


CREATE TABLE IF NOT EXISTS ext_trades (
    trade_id            NUMBER(15),
    external_trade_ref  VARCHAR2(40),
    source_system       VARCHAR2(20),
    trade_date          DATE,
    instrument_id       NUMBER(10),
    counterparty_id     NUMBER(10),
    account_id          NUMBER(10),
    side                VARCHAR2(4),
    quantity            NUMBER(15,2),
    price               NUMBER(15,4),
    currency            VARCHAR2(3),
    gross_amount        NUMBER(20,2),
    commission          NUMBER(15,4),
    venue_mic           VARCHAR2(4),
    executed_at         TIMESTAMP
)
ORGANIZATION EXTERNAL (
    TYPE ORACLE_LOADER
    DEFAULT DIRECTORY qs_staged
    ACCESS PARAMETERS (
        RECORDS DELIMITED BY NEWLINE
        SKIP 1
        BADFILE     qs_staged:'ext_trades.bad'
        LOGFILE     qs_staged:'ext_trades.log'
        DISCARDFILE qs_staged:'ext_trades.dsc'
        FIELDS TERMINATED BY ','
        OPTIONALLY ENCLOSED BY '"'
        LRTRIM
        MISSING FIELD VALUES ARE NULL
        (
            trade_id           CHAR,
            external_trade_ref CHAR,
            source_system      CHAR,
            trade_date         CHAR(10) DATE_FORMAT DATE MASK "YYYY-MM-DD",
            instrument_id      CHAR,
            counterparty_id    CHAR,
            account_id         CHAR,
            side               CHAR,
            quantity           CHAR,
            price              CHAR,
            currency           CHAR,
            gross_amount       CHAR,
            commission         CHAR,
            venue_mic          CHAR,
            executed_at        CHAR(20) DATE_FORMAT TIMESTAMP MASK "YYYY-MM-DD HH24:MI:SS"
        )
    )
    LOCATION ('placeholder.csv')
)
REJECT LIMIT UNLIMITED
/
