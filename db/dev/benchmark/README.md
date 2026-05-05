# UDF Throughput Benchmark — Scala Scalar vs Python Vectorized

**Purpose:** Measure the per-row throughput difference between the existing Scala scalar
UDFs (JAR-based) and Python `@vectorized` UDFs when applied to a 100-million-row dataset.
Results feed the performance estimates table in `docs/20260428_Architecture_v3.md §
Performance Estimates`.

---

## Files

| File | Description |
|------|-------------|
| `01_setup.sql` | Create `LOCID_DEV.BENCHMARK` schema, 50M mockup row table, and results table |
| `02_proxy_scalar_python.sql` | Register Python **scalar** UDF `PROXY_SCALAR` — per-row dispatch |
| `03_proxy_vectorized_python.sql` | Register Python **vectorized** UDF `PROXY_VECTORIZED` — batch dispatch, numpy proxy |
| `04_run_timing.sql` | Time all four approaches on 50M rows; insert results into `BENCHMARK_RESULTS` |
| `05_whl_vectorized.sql` | Register Python **vectorized** UDF `PROXY_WHL` — batch dispatch, actual `mb-locid-encoding` WHL |

---

## Four Approaches Timed

| Approach | UDF | Language | Dispatch | Operation |
|----------|-----|----------|----------|-----------|
| **A — Scala scalar (JAR)** | `LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT` | Scala 2.13 | Per-row | AES-128 ECB |
| **B — Python scalar proxy** | `LOCID_DEV.BENCHMARK.PROXY_SCALAR` | Python 3.11 | Per-row | HMAC-SHA256 proxy |
| **C — Python vectorized proxy** | `LOCID_DEV.BENCHMARK.PROXY_VECTORIZED` | Python 3.11 | Batch (1K–8K rows/batch) | numpy BLAS polynomial hash proxy |
| **D — Python vectorized (WHL)** | `LOCID_DEV.BENCHMARK.PROXY_WHL` | Python 3.11 | Batch (1K–8K rows/batch) | `locid_sf.encode_stable_cloc` (actual production WHL) |

### Compute operations

**Approach A** calls `LOCID_BASE_ENCRYPT` (AES-128 ECB via encode-lib JAR) per row.

**Approach B** uses `hashlib.SHA256` as a compute proxy — re-derives the key on every row,
matching the per-row `toKey()` pattern in the Scala scalar UDFs.

**Approach C** uses a **numpy polynomial hash** via BLAS `dot()` — no Python-level loop in
the hot path. SHA-256 was replaced because it has no numpy batch interface, which would make
the `@vectorized` implementation equivalent to a Python loop. C isolates the batching overhead
from the operation cost.

**Approach D** uses the actual `mb-locid-encoding` WHL (`locid_sf.encode_stable_cloc` —
SHA-1 UUID5 via the production library). This is the definitive Python vectorized measurement:
real production code, real cryptographic primitives, `@vectorized` batch dispatch.

### Results — 50M rows

> Run all four approaches and populate this table from `BENCHMARK_RESULTS`:
> ```sql
> SELECT approach, warehouse_size, elapsed_s, krows_per_s, run_at
> FROM   LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS
> ORDER  BY approach, run_at DESC;
> ```

| Approach | Handler | Elapsed (s) | Throughput (krows/s) | vs A warm | Notes |
|----------|---------|:-----------:|:--------------------:|:---------:|-------|
| A — Scala scalar, cold JVM | AES-128 ECB via encode-lib | — | — | — | |
| A — Scala scalar, warm JVM | AES-128 ECB via encode-lib | — | — | 1.0× | Steady state |
| B — Python scalar proxy | SHA-256 per row | — | — | — | |
| C — Python vectorized proxy | numpy BLAS polynomial hash | — | — | — | |
| D — Python vectorized (WHL) | `locid_sf.encode_stable_cloc` | — | — | — | |

### Warm-up for Scala UDFs

The cold-start overhead (~200 ms, one-time per warehouse session) is handled automatically by
the `LOCID_ENCRYPT` and `LOCID_DECRYPT` stored procedures — each proc issues a single-row
`LOCID_BASE_ENCRYPT` call after secrets are loaded and before the main production query.
The `jvm_warmup_s` field in `APP_LOGS` shows the actual cost per job.

For the benchmark, the warm-up is built into `04_run_timing.sql` via `USE_CACHED_RESULT = FALSE`
and the sequential run order (A runs first, warming the JVM for B, C, and D in the same session).

The **3–5× improvement** estimate in the architecture doc applies to the actual `locid.py`
workload (Approach D) vs warm Scala (Approach A), where SHA-1 UUID5 key derivation costs
meaningfully more per row than the proxy, making key amortisation and reduced boundary
crossings impactful.

---

## Prerequisites

1. `db/dev/provider/01_setup.sql` through `06_udfs.sql` already run (`LOCID_DEV.STAGING` schema
   and `LOCID_BASE_ENCRYPT` UDF must exist for Approach A).
2. Warehouse available (XS minimum; larger warehouse recommended for faster 50M setup).
3. A valid `base_locid_secret` value (from the LocID Central license response) — required for
   Approach A only. Set as `$base_locid_secret` in `04_run_timing.sql` before running.
4. **For Approach D only:** Upload the `mb-locid-encoding` wheel to the stage before running
   `05_whl_vectorized.sql`. Replace the wheel filename in the IMPORTS path if needed:
   ```bash
   snow stage copy /path/to/dist/mb_locid_encoding-0.0.0-py3-none-any.whl \
       @LOCID_DEV.STAGING.LOCID_STAGE --connection <your_connection> --overwrite
   ```
   Verify: `LIST @LOCID_DEV.STAGING.LOCID_STAGE;`

> **Result cache warning.** Snowflake caches exact query results for 24 hours. If `MOCKUP_50M`
> is recreated with the same deterministic data, the result fingerprint matches the cache and all
> approaches return in ~60–70 ms regardless of true UDF cost. `04_run_timing.sql` includes
> `ALTER SESSION SET USE_CACHED_RESULT = FALSE` to prevent this.

> **Setup runtime.** Generating 50M rows in `01_setup.sql` takes ~10–20 minutes on an XS
> warehouse. Run on a larger warehouse to reduce setup time if needed.

---

## Run Order

**Full clean run** (first time or after cleanup):

```
01_setup.sql                   -- once; ~10–20 min on XS to generate 50M rows
02_proxy_scalar_python.sql     -- register PROXY_SCALAR
03_proxy_vectorized_python.sql -- register PROXY_VECTORIZED (numpy BLAS proxy)
05_whl_vectorized.sql          -- register PROXY_WHL (actual mb-locid-encoding WHL); stage wheel first
04_run_timing.sql              -- set $base_locid_secret first, then run all four timings
```

**Before re-running timings**, truncate old results to keep the table clean:

```sql
TRUNCATE TABLE LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS;
```

---

## Interpreting Results

Query the `BENCHMARK_RESULTS` table for a summary:

```sql
SELECT approach, rows_processed, elapsed_s,
       ROUND(rows_processed / elapsed_s / 1000, 1) AS krows_per_s
FROM   LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS
ORDER  BY approach, run_at DESC;
```

- **D/A ratio** — Python vectorized WHL vs Scala scalar; the definitive production speedup estimate.
- **C/A ratio** — numpy proxy vs Scala scalar; isolates dispatch overhead from operation cost.
- **B/C ratio** — isolates the `@vectorized` batch-dispatch gain from the operation cost.
- **B/A ratio** — Python scalar vs Scala scalar; Python runtime overhead independent of batching.

---

## Cleanup

Run the following to drop all benchmark objects and the schema. `01_setup.sql` is idempotent
and will recreate everything from scratch.

```sql
USE ROLE LOCID_APP_ADMIN;

-- Drop UDFs
DROP FUNCTION IF EXISTS LOCID_DEV.BENCHMARK.PROXY_SCALAR(VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS LOCID_DEV.BENCHMARK.PROXY_VECTORIZED(VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS LOCID_DEV.BENCHMARK.PROXY_WHL(VARCHAR, VARCHAR);

-- Drop tables
DROP TABLE IF EXISTS LOCID_DEV.BENCHMARK.MOCKUP_50M;
DROP TABLE IF EXISTS LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS;

-- Drop schema
DROP SCHEMA IF EXISTS LOCID_DEV.BENCHMARK CASCADE;
```
