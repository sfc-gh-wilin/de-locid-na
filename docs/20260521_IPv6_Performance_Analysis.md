# IPv6 Performance Analysis & Optimization Proposal

**Date:** 2026-05-21  
**Status:** In Progress  
**Environment:** LocID Provider Account (`JZAEQUY-QOC14949`)

---

## Executive Summary

IPv6 network block matching (inputs ending in `::`) is significantly slower than IPv6 device addresses or IPv4. This document explains why, provides current benchmarks, and proposes a **Provider-side exploded table** solution that would convert the expensive BETWEEN range join into a fast equi-join — achieving IPv4-like performance for IPv6.

---

## Current Performance (Patch 7, Large Snowpark-Optimized)

| Input Type | Table | Rows | Warm WH | Cold WH | Match Rate |
|-----------|-------|------|:-------:|:-------:|:----------:|
| IPv4 | `CUSTOMER_TEST_INPUT_1M_IPV4` | 1M | 17.8 min | ~18 min | 100% |
| IPv6 device addresses | `CUSTOMER_TEST_INPUT_1M_IPV6` | 1M | ~9 min* | ~15 min* | 100% |
| **IPv6 network blocks** | **`INPUT_IPV6_ONE_MIL`** | **1M** | **29 min** | **>60 min** | **100%** |

*Estimated from earlier benchmarks

---

## Why IPv6 Network Blocks Are Slow

### The Data

- `LOCID_BUILDS` has **58.3 billion** total rows, **~700 million IPv6 rows per build date**
- IPv6 builds are stored as hex ranges: `start_ip_int_hex` to `end_ip_int_hex`
- Matching requires: `input_ip_hex BETWEEN start_ip_int_hex AND end_ip_int_hex`

### The Problem: BETWEEN Range Joins

**IPv4** uses an "exploded" table (`LOCID_BUILDS_IPV4_EXPLODED`) with one row per individual IP address → enables hash equi-join (`input_ip = exploded.ip_address`). This is O(n) — extremely fast.

**IPv6** cannot be exploded to individual addresses (2^128 space). Instead it uses BETWEEN range joins — Snowflake must evaluate whether each input IP falls within each candidate range. This is fundamentally O(n × m) even with clustering/pruning.

### Network Blocks vs Device Addresses

| Property | Device Addresses | Network Blocks |
|----------|:----------------:|:--------------:|
| Example | `2001:4456:e0ff:6c28:eb94:8b0c:2d36:7dc7` | `2806:108E:E:D03A::` |
| Hex representation | Full 32-char random | 16 meaningful chars + 16 zeros |
| Distinct /64 prefixes (1M inputs) | 455K | 210K |
| Build rows matching input prefixes (16-char) | **393** | **269K** |
| Build rows matching input prefixes (12-char) | 58M | **523M** |

Device addresses are highly specific — they match at a fine-grained level. Network blocks are ambiguous — they could fall into many overlapping build ranges.

### Pass-by-Pass Breakdown (Network Blocks, 29 min warm)

| Pass | Prefix | Source | Duration | Notes |
|------|--------|--------|:--------:|-------|
| Builds materialisation | 16-char | LOCID_BUILDS | 116s | 269K narrow blocks only |
| **Pass 1** (prefix=12) | Narrow table | TBL_V6_BUILDS | **720s** | 1M IPs × 269K narrow ranges |
| **Pass 2** (prefix=10) | Source table | LOCID_BUILDS | **618s** | ~720K unmatched IPs × clustered source |
| Pass 3 (prefix=8) | Source table | LOCID_BUILDS | 163s | Few remaining IPs |
| Pass 4 (prefix=6) | Source table | LOCID_BUILDS | 23s | |
| Pass 5 (prefix=4) | Source table | LOCID_BUILDS | 58s | |
| Output write | | | 14s | |
| **Total matching** | | | **~1,700s** | |

---

## Proposed Solution: IPv6 /56 Exploded Table

### Concept

Create `LOCID_BUILDS_IPV6_EXPLODED` — analogous to the IPv4 exploded table but at the **/56 prefix level** (14 hex chars). Each build range is expanded into one row per /56 block it covers.

### Why /56?

| Granularity | Hex Chars | Explosion Factor | Total Rows (all builds) | Equi-join Selectivity |
|-------------|:---------:|:----------------:|:-----------------------:|:---------------------:|
| /48 (current semi-join) | 12 | 1.0× | 694M/build | ~523M candidates per job |
| **/56 (proposed)** | **14** | **1.8×** | **~56B total** | **~30 candidates per IP** |
| /60 | 15 | 15.2× | ~470B total | Too large |
| /64 | 16 | 232× | ~4.7T total | Impractical |

The /56 level is the sweet spot:
- **1.8× storage increase** — comparable to existing table sizes
- **Enables equi-join** on `SUBSTR(ip_hex, 1, 14)` — hash join, not range join
- Only **~30 candidates** per input IP need the final BETWEEN check (trivial)

### Table Schema

```sql
CREATE TABLE LOCID.STAGING.LOCID_BUILDS_IPV6_EXPLODED (
    BUILD_DT            DATE            NOT NULL,
    PREFIX_56           VARCHAR(14)     NOT NULL,   -- equi-join key (first 14 hex chars)
    START_IP_INT_HEX    VARCHAR(32)     NOT NULL,   -- original range start (for BETWEEN)
    END_IP_INT_HEX      VARCHAR(32)     NOT NULL,   -- original range end (for BETWEEN)
    START_IP            VARCHAR         NOT NULL,
    END_IP              VARCHAR         NOT NULL,
    TIER                VARCHAR,
    LOCID_COUNTRY       VARCHAR,
    LOCID_COUNTRY_CODE  VARCHAR,
    LOCID_REGION        VARCHAR,
    LOCID_REGION_CODE   VARCHAR,
    LOCID_CITY          VARCHAR,
    LOCID_CITY_CODE     VARCHAR,
    LOCID_POSTAL_CODE   VARCHAR,
    ENCRYPTED_LOCID     VARCHAR,
    LOCID_HORIZONTAL_ACCURACY VARCHAR
)
CLUSTER BY (PREFIX_56, BUILD_DT);
```

### Population Query (per build_dt)

```sql
-- For ranges within a single /56 block (45% of rows): 1 row each
INSERT INTO LOCID_BUILDS_IPV6_EXPLODED
SELECT 
    BUILD_DT,
    SUBSTR(START_IP_INT_HEX, 1, 14) AS PREFIX_56,
    START_IP_INT_HEX, END_IP_INT_HEX,
    START_IP, END_IP, TIER,
    LOCID_COUNTRY, LOCID_COUNTRY_CODE,
    LOCID_REGION, LOCID_REGION_CODE,
    LOCID_CITY, LOCID_CITY_CODE,
    LOCID_POSTAL_CODE, ENCRYPTED_LOCID, LOCID_HORIZONTAL_ACCURACY
FROM LOCID_BUILDS
WHERE START_IP LIKE '%:%'
  AND SUBSTR(START_IP_INT_HEX, 1, 14) = SUBSTR(END_IP_INT_HEX, 1, 14)
  AND BUILD_DT = :build_dt;

-- For ranges spanning multiple /56 blocks (55% of rows): explode
INSERT INTO LOCID_BUILDS_IPV6_EXPLODED
SELECT 
    l.BUILD_DT,
    SUBSTR(l.START_IP_INT_HEX, 1, 12) || LPAD(TO_VARCHAR(seq.val, 'XX'), 2, '0') AS PREFIX_56,
    l.START_IP_INT_HEX, l.END_IP_INT_HEX,
    l.START_IP, l.END_IP, l.TIER,
    l.LOCID_COUNTRY, l.LOCID_COUNTRY_CODE,
    l.LOCID_REGION, l.LOCID_REGION_CODE,
    l.LOCID_CITY, l.LOCID_CITY_CODE,
    l.LOCID_POSTAL_CODE, l.ENCRYPTED_LOCID, l.LOCID_HORIZONTAL_ACCURACY
FROM LOCID_BUILDS l
CROSS JOIN (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 + 
           TO_NUMBER(SUBSTR(l.START_IP_INT_HEX, 13, 2), 'XX') AS val
    FROM TABLE(GENERATOR(ROWCOUNT => 256))
) seq
WHERE l.START_IP LIKE '%:%'
  AND SUBSTR(l.START_IP_INT_HEX, 1, 12) = SUBSTR(l.END_IP_INT_HEX, 1, 12)
  AND SUBSTR(l.START_IP_INT_HEX, 1, 14) != SUBSTR(l.END_IP_INT_HEX, 1, 14)
  AND seq.val BETWEEN TO_NUMBER(SUBSTR(l.START_IP_INT_HEX, 13, 2), 'XX')
                  AND TO_NUMBER(SUBSTR(l.END_IP_INT_HEX, 13, 2), 'XX')
  AND l.BUILD_DT = :build_dt;
```

### Updated Encrypt Procedure (Matching Logic)

```sql
-- Current (BETWEEN range join against 700M rows):
SELECT ...
FROM input i
JOIN LOCID_BUILDS l
    ON i.build_dt = l.build_dt
    AND i.ip_hex BETWEEN l.start_ip_int_hex AND l.end_ip_int_hex

-- Proposed (equi-join + small BETWEEN filter):
SELECT ...
FROM input i
JOIN LOCID_BUILDS_IPV6_EXPLODED e
    ON i.build_dt = e.build_dt
    AND SUBSTR(i.ip_hex, 1, 14) = e.prefix_56           -- equi-join (hash)
    AND i.ip_hex BETWEEN e.start_ip_int_hex AND e.end_ip_int_hex  -- filter (~30 rows)
QUALIFY ROW_NUMBER() OVER (PARTITION BY i._id ORDER BY e.build_dt DESC) = 1
```

### Expected Performance

| Metric | Current (BETWEEN) | Proposed (Equi-join + filter) |
|--------|:-----------------:|:----------------------------:|
| Join type | Range/nested-loop | Hash equi-join |
| Candidate rows per input IP | ~hundreds of thousands | ~30 |
| Clustering benefit | Moderate (START_IP_INT_HEX) | High (PREFIX_56) |
| Estimated 1M network blocks | 29+ min (warm), >60 min (cold) | **5-10 min** (estimated) |
| Cold/warm sensitivity | High | Low (equi-join prunes efficiently) |

### Implementation Requirements

| Step | Owner | Effort |
|------|-------|--------|
| 1. Create exploded table DDL | Snowflake SA (us) | Done (above) |
| 2. Population query / ETL | **LocID** (Provider data pipeline) | Add to weekly Airflow DAG |
| 3. Add to Secure View + share | Snowflake SA (us) | `03_share_to_pkg.sql` update |
| 4. Update encrypt procedure | Snowflake SA (us) | Replace 6-pass loop with equi-join |
| 5. Add clustering keys | **LocID** | `ALTER TABLE ... CLUSTER BY (PREFIX_56, BUILD_DT)` |

### Storage Impact

| Table | Rows | Estimated Size |
|-------|------|:-------------:|
| LOCID_BUILDS (current) | 58.3B | 2.15 TB |
| LOCID_BUILDS_IPV4_EXPLODED (current) | 253B | 2.25 TB |
| **LOCID_BUILDS_IPV6_EXPLODED (proposed)** | **~56B** | **~2 TB** |

---

## Short-Term Recommendations (Before Exploded Table)

1. **Use XL Snowpark-optimized** for 1M+ IPv6 network block workloads
2. **Keep warehouse warm** — set `AUTO_SUSPEND = 900` (15 min minimum)
3. **Run via SQL worksheet** for jobs >30 min (no session timeout)
4. **Split large batches** — process 500K rows at a time for more predictable runtimes

---

## Decision Required from LocID

The IPv6 exploded table approach requires LocID to:
1. Create and maintain the `/56 exploded table` (~56B rows, ~2TB) in their weekly build pipeline
2. Confirm storage budget for the additional ~2TB
3. Confirm the Airflow DAG can include the explosion step

**Alternatively**, if storage is a concern, a **/48 level explosion** (12 hex chars) gives 1:1 rows (no explosion needed) but still requires the BETWEEN range join within each /48 bucket. This is essentially what the current `pfx12` semi-join does — no improvement.

The **/56 level is the minimum viable exploded table** that provides meaningful equi-join benefit.
