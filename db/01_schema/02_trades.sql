/*
===============================================================================
DDL: TRADES — the central fact table
===============================================================================
Purpose:
    Stores every trade. This is the one large table in the project and the
    table that all three phases (Ingest, Process, Report) operate on.

Overview:
    Range-interval partitioned by trade_date, one partition per month. Oracle
    creates new monthly partitions automatically as data with new dates
    arrives. Partitioning is what lets the Process phase update a single day's
    trades by touching exactly one partition instead of the whole table — the
    central optimization this project demonstrates.

Column lifecycle:
    The Ingest phase loads the raw feed columns (external_trade_ref ..
    executed_at). The Process phase then DERIVES three columns in bulk:
        - settlement_date  (trade_date + 2 business days)
        - net_amount       (gross_amount adjusted by commission and side)
        - processed        (flipped from 'N' to 'Y')
    So a freshly-ingested row has settlement_date = NULL, net_amount = NULL,
    processed = 'N' until the Process phase runs.

Index strategy:
    - PK on (trade_date, trade_id) so the PK index can be LOCAL.
    - GLOBAL unique index on (source_system, external_trade_ref) — a single
      trade lookup must not have to scan every partition.
    - LOCAL indexes on the common filter/join columns, all prefixed with or
      paired with trade_date so they stay partition-aligned.
===============================================================================
*/


CREATE SEQUENCE IF NOT EXISTS seq_trade_id START WITH 1 INCREMENT BY 1 CACHE 1000
/


-------------------------------------------------------------------------------
-- trades
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS trades (
    -- identity
    trade_id            NUMBER(15)     NOT NULL,
    external_trade_ref  VARCHAR2(40)   NOT NULL,
    source_system       VARCHAR2(20)   NOT NULL,

    -- raw feed columns (populated by the Ingest phase)
    trade_date          DATE           NOT NULL,
    instrument_id       NUMBER(10)     NOT NULL,
    counterparty_id     NUMBER(10)     NOT NULL,
    account_id          NUMBER(10)     NOT NULL,
    side                VARCHAR2(4)    NOT NULL,
    quantity            NUMBER(15,2)   NOT NULL,
    price               NUMBER(15,4)   NOT NULL,
    currency            VARCHAR2(3)    NOT NULL,
    gross_amount        NUMBER(20,2)   NOT NULL,
    commission          NUMBER(15,4)   DEFAULT 0 NOT NULL,
    venue_mic           VARCHAR2(4),
    executed_at         TIMESTAMP      NOT NULL,

    -- derived columns (populated by the Process phase; NULL until then)
    settlement_date     DATE,
    net_amount          NUMBER(20,2),
    processed           VARCHAR2(1)    DEFAULT 'N' NOT NULL,

    -- housekeeping
    created_at          TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at          TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT pk_trades          PRIMARY KEY (trade_date, trade_id) USING INDEX LOCAL,
    CONSTRAINT ck_trades_side     CHECK (side IN ('BUY','SELL')),
    CONSTRAINT ck_trades_qty      CHECK (quantity > 0),
    CONSTRAINT ck_trades_price    CHECK (price > 0),
    CONSTRAINT ck_trades_proc     CHECK (processed IN ('Y','N'))
)
TABLESPACE qs_data
PARTITION BY RANGE (trade_date)
INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(
    PARTITION p_trades_history VALUES LESS THAN (DATE '2025-01-01')
)
/


-------------------------------------------------------------------------------
-- indexes
-------------------------------------------------------------------------------

-- GLOBAL: a single-trade lookup by business reference must not scan all
-- partitions. Enforces ingest idempotency across the whole table.
CREATE UNIQUE INDEX IF NOT EXISTS uk_trades_source_ref
    ON trades (source_system, external_trade_ref)
    TABLESPACE qs_index
/

-- LOCAL: partition-aligned, for joins back to the instrument dimension.
CREATE INDEX IF NOT EXISTS ix_trades_instrument
    ON trades (instrument_id, trade_date)
    LOCAL TABLESPACE qs_index
/

-- LOCAL: partition-aligned, for joins back to the counterparty dimension.
CREATE INDEX IF NOT EXISTS ix_trades_counterparty
    ON trades (counterparty_id, trade_date)
    LOCAL TABLESPACE qs_index
/

-- LOCAL: the Report phase groups by (trade_date, account_id).
CREATE INDEX IF NOT EXISTS ix_trades_account
    ON trades (account_id, trade_date)
    LOCAL TABLESPACE qs_index
/

-- LOCAL: the Process phase finds not-yet-processed trades for a date.
CREATE INDEX IF NOT EXISTS ix_trades_processed
    ON trades (trade_date, processed)
    LOCAL TABLESPACE qs_index
/
