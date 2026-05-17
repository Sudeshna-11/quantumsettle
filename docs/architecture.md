# Architecture

This is the deeper-dive companion to [`flow.md`](flow.md). Read `flow.md` first
for the step-by-step walkthrough; this file explains the *why* of the design
choices.

## Component map

```
┌────────────────────────────────────────────────────────────────────────────┐
│                            Python layer (py/)                              │
│                                                                            │
│  faker/         generates simulated trade feeds (CSV in data/staged/)      │
│  scripts/       admin_setup, migrate, check_db, schema_summary,            │
│                 ingest, process, report, run_tests, show_errors            │
│  bench/         run.py — 3-phase timing harness                            │
│                 explain.py — EXPLAIN PLAN side-by-side report              │
│  api/           FastAPI + Jinja2 dashboard                                 │
└──────────────────────────────────┬─────────────────────────────────────────┘
                                   │  python-oracledb (thin mode)
                                   ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                       Oracle 23ai Free (Docker)                            │
│                                                                            │
│  EXT_TRADES               external table over data/staged/*.csv            │
│                                                                            │
│  TRADES                   range-partitioned by trade_date (monthly)        │
│  BATCH_AUDIT              one row per package run                          │
│  INGEST_ERRORS            row-level rejection log                          │
│  ERROR_LOG                general error capture (autonomous tx)            │
│  PERF_METRICS             benchmark timing rows                            │
│                                                                            │
│  Shared (db/02_common):                                                    │
│    PKG_OPS                begin_batch/end_batch/log_ingest_error/log_error │
│    PKG_PERF               start_run/end_run/explain_plan/reset_for_bench   │
│                                                                            │
│  Optimized (db/04_optimized):                                              │
│    PKG_INGEST_OPTIMIZED   FORALL + BULK COLLECT + SAVE EXCEPTIONS          │
│    PKG_PROCESS_OPTIMIZED  set-based UPDATE, partition-pruned               │
│    PKG_REPORT_OPTIMIZED   reads MV_DAILY_PNL                               │
│                                                                            │
│  Not optimized (db/05_not_optimized):                                      │
│    PKG_INGEST_NOT_OPTIMIZED   cursor FOR loop, INSERT per row              │
│    PKG_PROCESS_NOT_OPTIMIZED  row-by-row UPDATE without trade_date         │
│    PKG_REPORT_NOT_OPTIMIZED   full GROUP BY with NO_REWRITE                │
│                                                                            │
│  Materialized view:                                                        │
│    MV_DAILY_PNL           fast-refresh on commit, query rewrite enabled    │
└────────────────────────────────────────────────────────────────────────────┘
```

## Why each design choice

### Partitioned `trades` table

The optimization story only works if there is something to prune. `trades` is
range-interval partitioned by `trade_date`, one partition per month. Oracle
creates new partitions automatically as new dates arrive. With a `WHERE
trade_date = :d` predicate the planner targets exactly one partition; without
that predicate it scans all of them. That is the 5× win on Phase 2.

### Local + global indexes (mixed strategy)

The PK `(trade_date, trade_id)` is LOCAL, so partition maintenance (TRUNCATE
PARTITION etc.) doesn't have to rebuild a global index. Joins that already
carry `trade_date` use LOCAL indexes for free. The unique business key
`(source_system, external_trade_ref)` is GLOBAL because a single-row lookup
on it must not scan every partition.

### `processed` flag instead of a state machine

The Process phase needs to know which trades are still un-derived. A simple
`processed VARCHAR2(1) DEFAULT 'N'` does that with one byte per row. (An
earlier iteration of this project had a full settlement state machine here;
removed during simplification — see `git log`.)

### MV_DAILY_PNL with REFRESH FAST ON COMMIT

The Report phase asks the same aggregation question over and over.
Aggregating millions of rows on every call is wasteful, so the aggregation is
kept permanently up-to-date by an MV. Every commit on `trades` triggers an
incremental refresh that applies just the delta from the MV log — the cost is
amortized across writes instead of paid in full on every read.

`ENABLE QUERY REWRITE` lets the optimizer transparently substitute the MV
even into a base-table query of a compatible shape. The `NOT_OPTIMIZED`
report uses `/*+ NO_REWRITE */` to defeat this so the benchmark measures the
genuine no-MV cost.

### Autonomous-transaction error log

`PKG_OPS.log_error` declares `PRAGMA AUTONOMOUS_TRANSACTION`. The log row
commits independently of the caller's transaction, so an error is still
recorded even when the caller subsequently rolls back. Without this you'd
log the error, hit an exception handler that rolls back, and the log row
would vanish along with the work.

### Two packages per phase

`PKG_*_OPTIMIZED` and `PKG_*_NOT_OPTIMIZED` are siblings under different
folders. Both compile, both install, both are callable from the CLI and the
benchmark. The CLI takes a `--variant` flag and dispatches to the right
package. No swapping, no installing on demand — just two callable namespaces.

## Data lifecycle

A single trade row passes through five states across the pipeline:

1. **Faked** — a row in a CSV under `data/staged/`.
2. **Visible** — exposed via `EXT_TRADES` (still on disk).
3. **Loaded** — in `TRADES`, `processed='N'`, `net_amount` and
   `settlement_date` still NULL.
4. **Processed** — `processed='Y'`, derived columns populated.
5. **Reported** — aggregated into `MV_DAILY_PNL`, visible to the dashboard.

Each transition is the responsibility of exactly one phase.

## Observability

- **`BATCH_AUDIT`** — every package run (begin_batch / end_batch).
- **`INGEST_ERRORS`** — row-level rejections captured by SAVE EXCEPTIONS.
- **`ERROR_LOG`** — general errors, written via autonomous transaction.
- **`PERF_METRICS`** — benchmark timings, keyed by `operation_name` and
  `variant`. Powers the `/perf` chart in the dashboard.

Run `python -m quantumsettle.scripts.ingest report` for a quick view of the
recent batches.
