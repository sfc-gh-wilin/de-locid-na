# UDF Throughput Benchmark — Scala Scalar vs Python Vectorized

**Purpose:** Measure the per-row throughput difference between the existing Scala scalar
UDFs (JAR-based) and a Python `@vectorized` UDF when applied to a 5-million-row dataset.
Results feed the performance estimates table in `docs/20260428_Architecture_v3.md §
Performance Estimates`.

---

## Files

| File | Description |
|------|-------------|
| `01_setup.sql` | Create `LOCID_DEV.BENCHMARK` schema + 5M mockup row table |
| `02_proxy_scalar_python.sql` | Python **scalar** UDF — per-row dispatch proxy |
| `03_proxy_vectorized_python.sql` | Python **vectorized** UDF — batch dispatch proxy |
| `04_run_timing.sql` | Timing queries for all three approaches + results summary |

---

## Three Approaches Timed

| Approach | UDF | Language | Dispatch |
|----------|-----|----------|----------|
| **A — Scala scalar (JAR)** | `LOCID_DEV.STAGING.LOCID_BASE_ENCRYPT` | Scala 2.13 | Per-row |
| **B — Python scalar proxy** | `LOCID_DEV.BENCHMARK.PROXY_SCALAR` | Python 3.11 | Per-row |
| **C — Python vectorized proxy** | `LOCID_DEV.BENCHMARK.PROXY_VECTORIZED` | Python 3.11 | Batch (1K–8K rows/batch) |

### Compute proxy

Approaches B and C use `hashlib.SHA256` as a compute proxy because `locid.py` (the Python
implementation of `encode-lib` operations) has not yet been provided by LocID.

### Actual results — XS warehouse, 5M rows (2026-04-28/29)

| Approach | Elapsed (s) | Throughput (krows/s) | Speedup vs A |
|----------|:-----------:|:--------------------:|:------------:|
| A — Scala scalar (JAR) | 0.316 | 15,823 | 1.0× |
| B — Python scalar proxy | 0.051 | 98,039 | 6.2× |
| C — Python vectorized proxy | 0.064 | 78,125 | 4.9× |

### Why C (vectorized) is slower than B (scalar)

Two compounding reasons:

1. **`Series.apply()` is still a Python for-loop.** The handler calls `df.iloc[:, 0].apply(lambda ...)`,
   which iterates element-by-element in Python at the pandas level — it is **not** a SIMD or
   numpy-native path. Per-element Python calls still occur inside each batch; the `@vectorized`
   decorator only reduces the number of Python↔SQL boundary crossings (from 5M to ~600–5000),
   not the number of Python function calls within each batch.

2. **The proxy operation is too cheap to expose the gain.** HMAC-SHA256 runs at ~10 ns/row.
   At that speed the boundary-crossing savings are negligible, and the pandas batch-management
   overhead (DataFrame construction, index alignment) outweighs them slightly.

The **3–5× improvement** estimate in the architecture doc applies to the actual `locid.py`
workload where AES-128 key derivation costs ~100–1000× more per row than SHA256, making key
amortisation and reduced crossings meaningful. Results will be re-run once `locid.py` is
available.

---

## Prerequisites

1. `db/dev/provider/01_setup.sql` through `06_udfs.sql` already run (STAGING schema +
   `LOCID_BASE_ENCRYPT` UDF must exist for Approach A).
2. Set `$base_locid_secret` in `04_run_timing.sql` before running Approach A.
3. Run `01_setup.sql` once to build the 5M mockup table.
4. Run `02_proxy_scalar_python.sql` and `03_proxy_vectorized_python.sql` to register UDFs.
5. Run `04_run_timing.sql` to execute all three benchmark queries and view results.

---

## Run Order

```
01_setup.sql              -- once; ~30–60 s to generate 5M rows
02_proxy_scalar_python.sql
03_proxy_vectorized_python.sql
04_run_timing.sql         -- set $base_locid_secret first
```

---

## Interpreting Results

Query the `BENCHMARK_RESULTS` table for a summary:

```sql
SELECT approach, rows_processed, elapsed_s,
       ROUND(rows_processed / elapsed_s / 1000, 1) AS krows_per_s
FROM   LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS
ORDER  BY approach;
```

The A/C ratio gives the Scala-scalar → Python-vectorized speedup estimate at the UDF phase.
The B/C ratio isolates the `@vectorized` batch-dispatch gain from the operation cost.
With the current SHA256 proxy, B ≈ C (both ~10 ns/row — too fast for batching savings to
dominate). Re-run with `locid.py` for production-accurate numbers.
