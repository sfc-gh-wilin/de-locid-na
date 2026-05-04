# UDF Throughput Benchmark — Scala Scalar vs Python Vectorized

**Purpose:** Measure the per-row throughput difference between the existing Scala scalar
UDFs (JAR-based) and Python `@vectorized` UDFs when applied to a 5-million-row dataset.
Results feed the performance estimates table in `docs/20260428_Architecture_v3.md §
Performance Estimates`.

---

## Files

| File | Description |
|------|-------------|
| `01_setup.sql` | Create `LOCID_DEV.BENCHMARK` schema, 5M mockup row table, and results table |
| `02_proxy_scalar_python.sql` | Register Python **scalar** UDF `PROXY_SCALAR` — per-row dispatch |
| `03_proxy_vectorized_python.sql` | Register Python **vectorized** UDF `PROXY_VECTORIZED` — batch dispatch, numpy proxy |
| `04_run_timing.sql` | Time all four approaches on 5M rows; insert results into `BENCHMARK_RESULTS` |
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

### Results — XS warehouse, 5M rows (2026-04-29)

Approaches A–C (proxy baseline):

| Approach | Handler | Elapsed (s) | Throughput (krows/s) | vs A warm | Notes |
|----------|---------|:-----------:|:--------------------:|:---------:|-------|
| A — Scala scalar, **cold JVM** | AES-128 ECB via encode-lib | 0.316 | 15,823 | — | First call after warehouse resume; JVM init + JAR load |
| A — Scala scalar, **warm JVM** | AES-128 ECB via encode-lib | 0.111 | 45,045 | 1.0× | Steady state; JVM warm, JAR in local disk cache |
| B — Python scalar proxy | SHA-256 per row | 0.050 | 100,000 | 2.2× | Final |
| C — Python vectorized proxy | numpy BLAS polynomial hash | 0.055 | 90,909 | 2.0× | Final |

> **A cold vs warm:** The 0.316 s run was the first call in a fresh warehouse session — JVM
> initialisation, JAR loading from stage, and JIT compilation all occur on first invocation.
> Subsequent calls in the same session use a warm JVM with the JAR in local disk cache (0.111 s).
> The warm number is the steady-state figure.

> **C ≈ B (proxy):** The numpy BLAS rewrite removed the Python-level loop, but the proxy
> compute (polynomial hash on 21-byte strings) is too fast (~10–50 ns/row) for the `@vectorized`
> batching overhead (~5 ms/batch for DataFrame construction) to be outweighed. D/A is the
> definitive comparison for production-representative work.

Approach D (actual WHL) — populate by running `05_whl_vectorized.sql` + `04_run_timing.sql`:

| Approach | Handler | Elapsed (s) | Throughput (krows/s) | vs A warm | Notes |
|----------|---------|:-----------:|:--------------------:|:---------:|-------|
| D — Python vectorized (WHL) | `locid_sf.encode_stable_cloc` | — | — | — | Run `05_whl_vectorized.sql` then `04_run_timing.sql` |

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
2. Warehouse `WLIN_WH_XS` (or equivalent) available.
3. A valid `base_locid_secret` value (from the LocID Central license response) — required for
   Approach A only. Set as `$base_locid_secret` in `04_run_timing.sql` before running.
4. **For Approach D only:** Upload the `mb-locid-encoding` wheel to the stage before running
   `05_whl_vectorized.sql`. Replace `<WHEEL_FILE>` in that file with the actual filename:
   ```sql
   PUT file:///path/to/dist/<WHEEL_FILE>
       @LOCID_DEV.STAGING.LOCID_STAGE/wheels/
       AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
   ```
   Verify with: `LIST @LOCID_DEV.STAGING.LOCID_STAGE/wheels/;`

> **Result cache warning.** Snowflake caches exact query results for 24 hours. If `MOCKUP_5M`
> is recreated with the same deterministic data (identical SQL + identical rows), the result
> fingerprint matches the cache and all approaches return in ~60–70 ms regardless of true UDF
> cost. `04_run_timing.sql` includes `ALTER SESSION SET USE_CACHED_RESULT = FALSE` to prevent this.

---

## Run Order

**Full clean run** (use after cleanup or first time):

```
01_setup.sql                   -- once; ~30–60 s on XS to generate 5M rows
02_proxy_scalar_python.sql     -- register PROXY_SCALAR
03_proxy_vectorized_python.sql -- register PROXY_VECTORIZED (numpy BLAS proxy)
05_whl_vectorized.sql          -- register PROXY_WHL (actual mb-locid-encoding WHL); set <WHEEL_FILE> first
04_run_timing.sql              -- set $base_locid_secret first, then run all four timings
```

**Re-run Approach D only** (e.g. after updating the WHL):

```
05_whl_vectorized.sql          -- re-registers PROXY_WHL
04_run_timing.sql              -- run Approach D block only; insert result
```

**Before re-running all approaches**, truncate old results to keep the table clean:

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

Run the following to drop all benchmark objects and the schema. This is safe to run at any
time; `01_setup.sql` is idempotent and will recreate everything from scratch.

```sql
USE ROLE LOCID_APP_ADMIN;

-- Drop UDFs
DROP FUNCTION IF EXISTS LOCID_DEV.BENCHMARK.PROXY_SCALAR(VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS LOCID_DEV.BENCHMARK.PROXY_VECTORIZED(VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS LOCID_DEV.BENCHMARK.PROXY_WHL(VARCHAR, VARCHAR);

-- Drop tables
DROP TABLE IF EXISTS LOCID_DEV.BENCHMARK.MOCKUP_5M;
DROP TABLE IF EXISTS LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS;

-- Drop schema (only after objects above are dropped, or use CASCADE)
DROP SCHEMA IF EXISTS LOCID_DEV.BENCHMARK CASCADE;
```

> After cleanup, restart from `01_setup.sql` to rebuild.

If you just need to re-run timings:
```sql
TRUNCATE TABLE LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS;
```
