-- =============================================================================
-- 02_ipv6_exploded_table.sql
-- LocID: Create and populate the IPv6 /56 exploded lookup table
--
-- Run order: AFTER 01_optimize_tables.sql. Can be re-run to refresh data.
--
-- Requires: ACCOUNTADMIN (or a role with CREATE TABLE on LOCID.STAGING).
--
-- Why this is needed:
--   IPv6 matching uses BETWEEN range joins against 700M+ rows per build date.
--   For inputs whose IPs land in densely-overlapping build ranges (e.g.,
--   network-block addresses ending in ::), the range join evaluates hundreds
--   of thousands of candidate rows per input IP.
--
--   This exploded table converts the BETWEEN range join into a fast equi-join
--   at the /56 prefix level (first 14 hex chars of the IPv6 hex address).
--   Each build range ≤ /48 is expanded into one row per /56 block it covers.
--   Wide ranges (> /48, ~31K source rows) are excluded — the encrypt procedure
--   handles these via a BETWEEN fallback against LOCID_BUILDS.
--
--   Geo context columns (country, region, city, etc.) are NOT stored here to
--   reduce storage cost. The encrypt procedure joins back to LOCID_BUILDS on
--   (build_dt, start_ip, end_ip) to retrieve geo context after the equi-join.
--
-- Explosion factor: ~1.8× (from 700M → ~71.4B rows across all build dates)
-- Total storage: ~71.4B rows (~2 TB estimated)
--
-- The encrypt procedure joins:
--   SUBSTR(input_ip_hex, 1, 14) = exploded.prefix_56   (equi-join / hash join)
--   AND input_ip_hex BETWEEN exploded.start_ip_int_hex AND exploded.end_ip_int_hex
--
-- This reduces candidates from hundreds of thousands → ~30 per input IP.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- =============================================================================
-- CONFIGURATION — set target_build_dt before running Step 2
-- =============================================================================
SET target_build_dt = 'YYYY-MM-DD';  -- Replace with the build date to process (e.g. '2026-05-20')
-- =============================================================================


-- =============================================================================
-- Step 1: Create the exploded table
-- =============================================================================

CREATE TABLE IF NOT EXISTS LOCID.STAGING.LOCID_BUILDS_IPV6_EXPLODED (
    BUILD_DT                  DATE            NOT NULL,
    PREFIX_56                 VARCHAR(14)     NOT NULL,
    START_IP                  VARCHAR         NOT NULL,
    END_IP                    VARCHAR         NOT NULL,
    START_IP_INT_HEX          VARCHAR(32)     NOT NULL,
    END_IP_INT_HEX            VARCHAR(32)     NOT NULL
)
CLUSTER BY (PREFIX_56, BUILD_DT);
-- Note: geo context columns (tier, country, region, city, postal code,
-- encrypted_locid, horizontal_accuracy) are intentionally excluded to
-- reduce storage. The encrypt procedure retrieves them by joining back
-- to LOCID_BUILDS on (build_dt, start_ip, end_ip) after the equi-join.


-- =============================================================================
-- Step 2: Populate the exploded table (per build_dt)
--
-- Run this for each build_dt you want to include. For a full refresh:
--   1. TRUNCATE TABLE LOCID.STAGING.LOCID_BUILDS_IPV6_EXPLODED;
--   2. Run both INSERT statements below for each build_dt.
--
-- For incremental updates (new weekly build):
--   1. DELETE FROM ... WHERE BUILD_DT = <new_build_dt>;  (if re-processing)
--   2. Run both INSERTs with BUILD_DT = <new_build_dt>.
-- =============================================================================

-- 2a: Narrow ranges (start/end share the same /56 prefix) — 1 row each, no explosion
--     These are ~45% of IPv6 build rows.
INSERT INTO LOCID.STAGING.LOCID_BUILDS_IPV6_EXPLODED
SELECT
    BUILD_DT,
    SUBSTR(START_IP_INT_HEX, 1, 14)  AS PREFIX_56,
    START_IP, END_IP,
    START_IP_INT_HEX, END_IP_INT_HEX
FROM LOCID.STAGING.LOCID_BUILDS
WHERE START_IP LIKE '%:%'
  AND SUBSTR(START_IP_INT_HEX, 1, 14) = SUBSTR(END_IP_INT_HEX, 1, 14)
  AND BUILD_DT = $target_build_dt;


-- 2b: Medium ranges (share /48 but span multiple /56 blocks) — explode
--     These are ~55% of IPv6 build rows, median 16 /56 blocks per range.
--
--     The explosion generates one row per /56 prefix that the range covers.
--     Uses a GENERATOR to produce sequential values between the start and end
--     /56 prefix offsets (hex chars 13-14 of start/end).
INSERT INTO LOCID.STAGING.LOCID_BUILDS_IPV6_EXPLODED
WITH source AS (
    SELECT *,
        TO_NUMBER(SUBSTR(START_IP_INT_HEX, 13, 2), 'XX') AS start_56_offset,
        TO_NUMBER(SUBSTR(END_IP_INT_HEX, 13, 2), 'XX')   AS end_56_offset
    FROM LOCID.STAGING.LOCID_BUILDS
    WHERE START_IP LIKE '%:%'
      AND SUBSTR(START_IP_INT_HEX, 1, 12) = SUBSTR(END_IP_INT_HEX, 1, 12)
      AND SUBSTR(START_IP_INT_HEX, 1, 14) != SUBSTR(END_IP_INT_HEX, 1, 14)
      AND BUILD_DT = $target_build_dt
),
seq AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS n
    FROM TABLE(GENERATOR(ROWCOUNT => 256))
)
SELECT
    s.BUILD_DT,
    SUBSTR(s.START_IP_INT_HEX, 1, 12) || LPAD(TO_VARCHAR(seq.n, 'XX'), 2, '0') AS PREFIX_56,
    s.START_IP, s.END_IP,
    s.START_IP_INT_HEX, s.END_IP_INT_HEX
FROM source s
JOIN seq ON seq.n BETWEEN s.start_56_offset AND s.end_56_offset;


-- 2c: Wide ranges (start/end differ at /48 level or wider) — excluded
--     These are <0.1% of IPv6 build rows. They span too many /56 blocks to
--     explode efficiently. The encrypt procedure handles these via a BETWEEN
--     fallback join against LOCID_BUILDS (Stage 2) for unmatched input IDs.


-- =============================================================================
-- Step 3: Verify
-- =============================================================================

-- Check row count for the build date
SELECT BUILD_DT, COUNT(*) AS row_count
FROM LOCID.STAGING.LOCID_BUILDS_IPV6_EXPLODED
WHERE BUILD_DT = '2026-05-13'
GROUP BY BUILD_DT;

-- Check clustering depth (run after Automatic Clustering has had time to process)
-- SELECT SYSTEM$CLUSTERING_INFORMATION('LOCID.STAGING.LOCID_BUILDS_IPV6_EXPLODED', '(PREFIX_56, BUILD_DT)');

-- Spot-check: verify a known input IP matches
-- SELECT *
-- FROM LOCID.STAGING.LOCID_BUILDS_IPV6_EXPLODED
-- WHERE BUILD_DT = '2026-05-13'
--   AND PREFIX_56 = SUBSTR('240149004E0602CB0000000000000000', 1, 14)
-- LIMIT 10;


-- =============================================================================
-- Usage in the Encrypt Procedure (reference — actual code in encrypt.sql)
-- =============================================================================
--
-- Stage 1: equi-join on /56 prefix (~99%+ of inputs)
--
--   SELECT i._id, i._ip, i._ts, lb.encrypted_locid, lb.tier,
--          lb.locid_country, lb.locid_country_code, ...
--   FROM {TBL_V6_DATED} i
--   JOIN LOCID_SHARE.LOCID_BUILDS_IPV6_EXPLODED e
--       ON  i.build_dt = e.build_dt
--       AND SUBSTR(i.ip_hex, 1, 14) = e.prefix_56         -- equi-join (hash)
--       AND i.ip_hex BETWEEN e.start_ip_int_hex AND e.end_ip_int_hex  -- ~30 rows
--   JOIN LOCID_SHARE.LOCID_BUILDS lb
--       ON  e.build_dt = lb.build_dt
--       AND e.start_ip = lb.start_ip                       -- geo context lookup
--       AND e.end_ip   = lb.end_ip
--   QUALIFY ROW_NUMBER() OVER (PARTITION BY i._id ORDER BY lb.build_dt DESC) = 1
--
-- Stage 2: BETWEEN fallback for unmatched IDs (wide ranges > /48 only)
--
--   INSERT INTO {TBL_IPV6}
--   SELECT i._id, i._ip, i._ts, l.encrypted_locid, l.tier, l.locid_country, ...
--   FROM {TBL_V6_DATED} i
--   LEFT JOIN {TBL_IPV6} matched ON i._id = matched._id
--   JOIN LOCID_SHARE.LOCID_BUILDS l
--       ON  i.build_dt = l.build_dt
--       AND l.start_ip LIKE '%:%'
--       AND SUBSTR(l.start_ip_int_hex, 1, 12) != SUBSTR(l.end_ip_int_hex, 1, 12)
--       AND i.ip_hex BETWEEN l.start_ip_int_hex AND l.end_ip_int_hex
--   WHERE matched._id IS NULL
--   QUALIFY ROW_NUMBER() OVER (PARTITION BY i._id ORDER BY l.build_dt DESC) = 1
