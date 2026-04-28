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

### Important caveat

Approaches B and C use `hashlib.HMAC-SHA256` as a **compute proxy** because the actual
`locid.py` Python source (which would call the same crypto as `encode-lib`) has not yet
been provided by LocID. The proxy has a similar per-row computational profile to AES-128
ECB, but the two should not be treated as producing byte-compatible output.

What the results *do* measure validly:
- **A vs B**: Scala-JVM scalar dispatch overhead vs Python scalar dispatch overhead.
- **B vs C**: Python-to-Python dispatch overhead gain from batching (`@vectorized`).
- **A vs C**: Combined picture — Scala scalar vs Python vectorized, noting the crypto
  difference. Once `locid.py` is available, replace the proxy body with the real
  implementation to get production-accurate numbers.

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

After `04_run_timing.sql`, query the `BENCHMARK_RESULTS` table:

```sql
SELECT approach, rows_processed, elapsed_s,
       ROUND(rows_processed / elapsed_s / 1000, 1) AS krows_per_s
FROM   LOCID_DEV.BENCHMARK.BENCHMARK_RESULTS
ORDER  BY approach;
```

The ratio `elapsed_s(A) / elapsed_s(C)` gives the overall speedup estimate for the
Scala-scalar → Python-vectorized migration at the UDF phase. Record this ratio in the
`### Performance Estimates` table in the architecture doc.
