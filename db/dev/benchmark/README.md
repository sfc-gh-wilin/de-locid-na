# UDF Throughput Benchmark — Scala Scalar vs Python Vectorized

**Purpose:** Measure the per-row throughput difference between the existing Scala scalar
UDFs (JAR-based) and a Python `@vectorized` UDF when applied to a 5-million-row dataset.
Results feed the performance estimates table in `docs/20260428_Architecture_v3.md §
Performance Estimates`.

---

## Files

| File | Description |
|------|-------------|
| `01_setup.sql` | Create `LOCID_DEV.BENCHMARK` schema, 5M mockup row table, and results table |
| `02_proxy_scalar_python.sql` | Register Python **scalar** UDF `PROXY_SCALAR` — per-row dispatch |
| `03_proxy_vectorized_python.sql` | Register Python **vectorized** UDF `PROXY_VECTORIZED` — batch dispatch |
| `04_run_timing.sql` | Time all three approaches on 5M rows; insert results into `BENCHMARK_RESULTS` |
| `04b_rerun_C_vectorized.sql` | Re-register `PROXY_VECTORIZED` and time Approach C only (use after updating the handler) |

---

## Three Approaches Timed

| Approach | UDF | Language | Dispatch |
|----------|-----|----------|----------|
| **A — Scala scalar (JAR)** | `LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT` | Scala 2.13 | Per-row |
| **B — Python scalar proxy** | `LOCID_DEV.BENCHMARK.PROXY_SCALAR` | Python 3.11 | Per-row |
| **C — Python vectorized proxy** | `LOCID_DEV.BENCHMARK.PROXY_VECTORIZED` | Python 3.11 | Batch (1K–8K rows/batch) |

### Compute proxy

Approach B uses `hashlib.SHA256` as a compute proxy.

Approach C uses a **numpy polynomial hash** via BLAS `dot()` — no Python-level loop in the hot path.
The critical path is all C/BLAS: `str.ljust/encode → b''.join → np.frombuffer().reshape →
arr.dot(_PRIMES) → hashes.astype(str)`. SHA-256 was replaced because it has no numpy batch
interface, which would have made the `@vectorized` implementation equivalent to a Python loop.

Both proxies are used only because `locid.py` (the Python implementation of `encode-lib` operations)
has not yet been provided by LocID. Results will be re-run with actual AES-128 operations once it
is available.

### Results — XS warehouse, 5M rows

| Approach | Handler | Elapsed (s) | Throughput (krows/s) | Speedup vs A | Status |
|----------|---------|:-----------:|:--------------------:|:------------:|--------|
| A — Scala scalar (JAR) | AES-128 ECB via encode-lib | 0.316 | 15,823 | 1.0× | Final |
| B — Python scalar proxy | SHA-256 per row | 0.051 | 98,039 | 6.2× | Final |
| C — Python vectorized proxy | SHA-256 + `Series.apply()` | 0.064 | 78,125 | 4.9× | **Pending re-run** |

> **C is pending re-run.** The handler was rewritten to use a true numpy BLAS polynomial
> hash (no Python-level loop). The 0.064 s result above is from the original `Series.apply()`
> implementation. Run `04b_rerun_C_vectorized.sql` to get the updated number.

### Why the original C was slower than B

Two compounding reasons:

1. **`Series.apply()` is still a Python for-loop.** The original handler called
   `df.iloc[:, 0].apply(lambda ...)`, which iterates element-by-element in Python — it is
   **not** a SIMD or numpy-native path. Per-element Python calls still occurred inside each
   batch; `@vectorized` only reduced Python↔SQL boundary crossings (from 5M to ~600–5000),
   not the Python function calls within each batch.

2. **The proxy operation was too cheap to expose the gain.** HMAC-SHA256 runs at ~10 ns/row.
   At that speed the boundary-crossing savings are negligible, and the pandas batch-management
   overhead (DataFrame construction, index alignment) outweighed them slightly.

The handler has been rewritten. The numpy polynomial hash eliminates Python-level per-row
calls from the hot path, which should show C ≥ B on the re-run.

The **3–5× improvement** estimate in the architecture doc applies to the actual `locid.py`
workload where AES-128 key derivation costs ~100–1000× more per row, making key amortisation
and reduced crossings meaningful.

---

## Prerequisites

1. `db/dev/provider/01_setup.sql` through `06_udfs.sql` already run (`LOCID_DEV.STAGING` schema
   and `LOCID_BASE_ENCRYPT` UDF must exist for Approach A).
2. Warehouse `WLIN_WH_XS` (or equivalent) available.
3. A valid `base_locid_secret` value (from the LocID Central license response) — required for
   Approach A only. Set as `$base_locid_secret` in `04_run_timing.sql` before running.

> **Result cache warning.** Snowflake caches exact query results for 24 hours. If `MOCKUP_5M`
> is recreated with the same deterministic data (identical SQL + identical rows), the result
> fingerprint matches the cache and all approaches return in ~60–70 ms regardless of true UDF
> cost. Both `04_run_timing.sql` and `04b_rerun_C_vectorized.sql` include
> `ALTER SESSION SET USE_CACHED_RESULT = FALSE` to prevent this.

---

## Run Order

**Full clean run** (use after cleanup or first time):

```
01_setup.sql                   -- once; ~30–60 s on XS to generate 5M rows
02_proxy_scalar_python.sql     -- register PROXY_SCALAR
03_proxy_vectorized_python.sql -- register PROXY_VECTORIZED (numpy BLAS handler)
04_run_timing.sql              -- set $base_locid_secret first, then run all three timings
```

**Re-run Approach C only** (e.g. after updating the vectorized handler):

```
04b_rerun_C_vectorized.sql     -- re-registers PROXY_VECTORIZED and times C only
```

**Before re-running**, truncate old results to keep the table clean:

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

- **A/C ratio** — Scala scalar → Python vectorized speedup estimate at the UDF phase.
- **B/C ratio** — isolates the `@vectorized` batch-dispatch gain from the operation cost.
- **B/A ratio** — Python scalar vs Scala scalar; shows Python runtime overhead independent of batching.

---

## Cleanup

Run the following to drop all benchmark objects and the schema. This is safe to run at any
time; `01_setup.sql` is idempotent and will recreate everything from scratch.

```sql
USE ROLE LOCID_APP_ADMIN;

-- Drop UDFs
DROP FUNCTION IF EXISTS LOCID_DEV.BENCHMARK.PROXY_SCALAR(VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS LOCID_DEV.BENCHMARK.PROXY_VECTORIZED(VARCHAR, VARCHAR);

-- Drop tables
DROP TABLE IF EXISTS LOCID_DEV.BENCHMARK.MOCKUP_5M;
DROP TABLE IF EXISTS LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS;

-- Drop schema (only after objects above are dropped, or use CASCADE)
DROP SCHEMA IF EXISTS LOCID_DEV.BENCHMARK CASCADE;
```

> After cleanup, restart from `01_setup.sql` to rebuild.
