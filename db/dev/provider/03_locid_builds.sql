-- =============================================================================
-- Table: LOCID_BUILDS
-- Description: Core LocID data lake. Contains IP-to-LocID mappings for both
--              IPv4 (ranges) and IPv6 (ranges + hex representations).
--              Updated weekly via Airflow DAG on LocID side.
--
-- IPv4 matching: joined via LOCID_BUILDS_IPV4_EXPLODED (equi-join), then back
--                to this table on (build_dt, start_ip, end_ip).
-- IPv6 matching: queried directly using start_ip_int_hex / end_ip_int_hex
--                with cascading prefix range joins (WHERE start_ip LIKE '%:%').
--
-- Clustering: (build_dt)
--   - All matching queries filter through LOCID_BUILD_DATES on build_dt first.
--   - Clustering on build_dt eliminates irrelevant micro-partitions early.
--
-- SOS candidate: evaluate Search Optimization Service on start_ip_int_hex
--                and end_ip_int_hex after data load for IPv6 range joins.
-- =============================================================================

USE ROLE LOCID_APP_ADMIN;

CREATE OR REPLACE TABLE LOCID_DEV.STAGING.LOCID_BUILDS (
    build_dt                  DATE     NOT NULL,  -- weekly build identifier
    start_ip                  VARCHAR  NOT NULL,  -- IP range start (IPv4 or IPv6)
    end_ip                    VARCHAR  NOT NULL,  -- IP range end   (IPv4 or IPv6)
    start_ip_int_hex          VARCHAR,            -- 32-char hex form of start_ip (IPv6 only)
    end_ip_int_hex            VARCHAR,            -- 32-char hex form of end_ip   (IPv6 only)
    tier                      VARCHAR,            -- location accuracy tier (e.g. T0 = rooftop, T1 = low)
    locid_country             VARCHAR,
    locid_country_code        VARCHAR,
    locid_region              VARCHAR,
    locid_region_code         VARCHAR,
    locid_city                VARCHAR,
    locid_city_code           VARCHAR,
    locid_postal_code         VARCHAR,
    encrypted_locid           VARCHAR  NOT NULL,  -- base LocID encrypted with base_locid_secret
    locid_horizontal_accuracy NUMBER              -- accuracy radius in meters
)
CLUSTER BY (build_dt);


