-- =============================================================================
-- Table: LOCID_BUILDS_IPV4_EXPLODED
-- Description: Exploded IPv4 lookup table. Each row represents a single IPv4
--              address (not a range), enabling a performant equi-join instead
--              of a range join. Joins back to LOCID_BUILDS on
--              (build_dt, start_ip, end_ip) to retrieve LocID and geo context.
--
-- Clustering: (ip_address, build_dt)
--   - ip_address: primary equi-join predicate from customer input data.
--   - build_dt: secondary filter to scope to the relevant weekly build.
--
-- SOS candidate: evaluate Search Optimization Service on ip_address after
--                data load if point-lookup performance needs further improvement.
-- =============================================================================

CREATE OR REPLACE TABLE LOCID_DEV.STAGING.LOCID_BUILDS_IPV4_EXPLODED (
    build_dt    DATE     NOT NULL,  -- weekly build identifier
    ip_address  VARCHAR  NOT NULL,  -- individual exploded IPv4 address
    start_ip    VARCHAR  NOT NULL,  -- FK to LOCID_BUILDS.start_ip
    end_ip      VARCHAR  NOT NULL   -- FK to LOCID_BUILDS.end_ip
)
CLUSTER BY (ip_address, build_dt);
