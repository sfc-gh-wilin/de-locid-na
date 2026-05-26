-- =============================================================================
-- Table: LOCID_BUILDS_IPV6_EXPLODED
-- Description: Exploded IPv6 /56 prefix lookup table. Each build range ≤ /48
--              is expanded into one row per /56 block it covers, enabling a
--              hash equi-join on PREFIX_56 instead of a BETWEEN range join.
--              Joins back to LOCID_BUILDS on (build_dt, start_ip, end_ip)
--              to retrieve geo context columns.
--
--              Wide ranges (> /48) are excluded. The encrypt procedure handles
--              those via a BETWEEN fallback (Stage 2) for unmatched IDs.
--
-- Clustering: (PREFIX_56, BUILD_DT)
--   - PREFIX_56: primary equi-join predicate (first 14 hex chars of ip_hex).
--   - BUILD_DT:  secondary filter to scope to the relevant weekly build.
--
-- Note: No geo context columns — minimal schema reduces storage cost.
--       The encrypt procedure retrieves geo context by joining back to
--       LOCID_BUILDS on (build_dt, start_ip, end_ip) after the equi-join.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;

CREATE OR REPLACE TABLE LOCID.STAGING.LOCID_BUILDS_IPV6_EXPLODED (
    build_dt          DATE            NOT NULL,  -- weekly build identifier
    prefix_56         VARCHAR(14)     NOT NULL,  -- first 14 hex chars of ip_hex (equi-join key)
    start_ip          VARCHAR         NOT NULL,  -- FK to LOCID_BUILDS.start_ip
    end_ip            VARCHAR         NOT NULL,  -- FK to LOCID_BUILDS.end_ip
    start_ip_int_hex  VARCHAR(32)     NOT NULL,  -- original range start hex (for BETWEEN filter)
    end_ip_int_hex    VARCHAR(32)     NOT NULL   -- original range end hex (for BETWEEN filter)
)
CLUSTER BY (prefix_56, build_dt);
