-- ---------------------------------------------------------------------------
-- Dimensional layer: conformed dimensions
--
-- Surrogate integer keys throughout. Natural keys are carried but never joined
-- on, so that a re-keyed source system does not break history.
--
-- Every dimension carries an "unknown" row at key -1. Facts join to it rather
-- than dropping rows or leaving NULLs, which keeps counts reconcilable against
-- the source.
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS mart;

-- ---- dim_date --------------------------------------------------------------

CREATE OR REPLACE TABLE mart.dim_date AS
WITH d AS (
    SELECT UNNEST(generate_series(DATE '2022-01-01', DATE '2027-12-31', INTERVAL 1 DAY))::DATE AS full_date
)
SELECT
    CAST(strftime(full_date, '%Y%m%d') AS INTEGER) AS date_key,
    full_date,
    EXTRACT(year    FROM full_date) AS calendar_year,
    EXTRACT(quarter FROM full_date) AS calendar_quarter,
    EXTRACT(month   FROM full_date) AS calendar_month,
    strftime(full_date, '%Y-%m')    AS year_month,
    CAST(strftime(full_date, '%Y%m') AS INTEGER) AS month_key,
    strftime(full_date, '%B')       AS month_name,
    EXTRACT(day     FROM full_date) AS day_of_month,
    strftime(full_date, '%A')       AS day_name,
    EXTRACT(dow FROM full_date) IN (0, 6) AS is_weekend,
    date_trunc('month', full_date)::DATE AS month_start_date,
    (date_trunc('month', full_date) + INTERVAL 1 MONTH - INTERVAL 1 DAY)::DATE AS month_end_date
FROM d;

INSERT INTO mart.dim_date
SELECT -1, NULL, NULL, NULL, NULL, 'UNKNOWN', -1, 'Unknown', NULL, 'Unknown', FALSE, NULL, NULL;

-- ---- dim_payer -------------------------------------------------------------

CREATE OR REPLACE TABLE mart.dim_payer AS
SELECT
    ROW_NUMBER() OVER (ORDER BY payer_name) AS payer_key,
    payer_id,
    payer_name,
    ownership,
    ownership = 'GOVERNMENT' AS is_public_plan
FROM stg.payer;

INSERT INTO mart.dim_payer VALUES (-1, 'UNKNOWN', 'Unknown payer', 'UNKNOWN', FALSE);

-- ---- dim_organization ------------------------------------------------------

CREATE OR REPLACE TABLE mart.dim_organization AS
SELECT
    ROW_NUMBER() OVER (ORDER BY organization_name) AS organization_key,
    organization_id,
    organization_name,
    city,
    province
FROM stg.organization;

INSERT INTO mart.dim_organization VALUES (-1, 'UNKNOWN', 'Unknown organization', NULL, NULL);

-- ---- dim_provider ----------------------------------------------------------

CREATE OR REPLACE TABLE mart.dim_provider AS
SELECT
    ROW_NUMBER() OVER (ORDER BY p.provider_name) AS provider_key,
    p.provider_id,
    p.provider_name,
    p.specialty,
    o.organization_key,
    o.organization_name
FROM stg.provider p
JOIN mart.dim_organization o USING (organization_id);

INSERT INTO mart.dim_provider VALUES (-1, 'UNKNOWN', 'Unknown provider', NULL, -1, 'Unknown organization');

-- ---- dim_procedure ---------------------------------------------------------

CREATE OR REPLACE TABLE mart.dim_procedure AS
SELECT
    ROW_NUMBER() OVER (ORDER BY procedure_code) AS procedure_key,
    procedure_code,
    procedure_desc
FROM stg.procedure_ref;

INSERT INTO mart.dim_procedure VALUES (-1, 'UNKNOWN', 'Unknown procedure');

-- ---- dim_diagnosis ---------------------------------------------------------

CREATE OR REPLACE TABLE mart.dim_diagnosis AS
SELECT
    ROW_NUMBER() OVER (ORDER BY diagnosis_code) AS diagnosis_key,
    diagnosis_code,
    -- ICD-10 chapter is derivable from the first character, and it is the
    -- grouping clinicians actually ask for
    CASE substr(diagnosis_code, 1, 1)
        WHEN 'E' THEN 'Endocrine, nutritional and metabolic'
        WHEN 'I' THEN 'Circulatory system'
        WHEN 'J' THEN 'Respiratory system'
        WHEN 'M' THEN 'Musculoskeletal and connective tissue'
        WHEN 'N' THEN 'Genitourinary system'
        WHEN 'F' THEN 'Mental and behavioural'
        WHEN 'Z' THEN 'Factors influencing health status'
        ELSE 'Other'
    END AS icd10_chapter
FROM stg.diagnosis_ref;

INSERT INTO mart.dim_diagnosis VALUES (-1, 'UNKNOWN', 'Other');

-- ---- dim_encounter_class ---------------------------------------------------

CREATE OR REPLACE TABLE mart.dim_encounter_class AS
SELECT
    ROW_NUMBER() OVER (ORDER BY encounter_class) AS encounter_class_key,
    encounter_class,
    setting,
    is_acute
FROM stg.encounter_class;

INSERT INTO mart.dim_encounter_class VALUES (-1, 'unknown', 'Unknown', FALSE);

-- ---- dim_member: Type 2 slowly changing dimension --------------------------
--
-- A new version opens whenever the member's coverage changes, which in this
-- source means a payer switch or a break in enrollment. Facts join on the
-- version that was in effect on the service date, so a claim incurred under
-- last year's plan stays attributed to that plan even after the member moves.
--
-- valid_to on the current row is 9999-12-31 rather than NULL, so BETWEEN works
-- without a COALESCE in every downstream join.

CREATE OR REPLACE TABLE mart.dim_member AS
WITH versions AS (
    SELECT
        e.member_id,
        e.payer_id,
        e.member_number,
        e.effective_date AS valid_from,
        e.end_date       AS valid_to,
        ROW_NUMBER() OVER (PARTITION BY e.member_id ORDER BY e.effective_date) AS version_number,
        ROW_NUMBER() OVER (PARTITION BY e.member_id ORDER BY e.effective_date DESC) = 1 AS is_current
    FROM stg.enrollment e
)
SELECT
    ROW_NUMBER() OVER (ORDER BY v.member_id, v.version_number) AS member_key,
    v.member_id,
    v.member_number,
    v.version_number,
    v.valid_from,
    CASE WHEN v.is_current THEN DATE '9999-12-31' ELSE v.valid_to END AS valid_to,
    v.is_current,
    m.birth_date,
    m.death_date,
    m.gender,
    m.city,
    m.province,
    -- age as at the start of this version, banded the way utilization is
    -- normally reported
    CAST(date_diff('year', m.birth_date, v.valid_from) AS INTEGER) AS age_at_version_start,
    CASE
        WHEN date_diff('year', m.birth_date, v.valid_from) < 18 THEN '00-17'
        WHEN date_diff('year', m.birth_date, v.valid_from) < 35 THEN '18-34'
        WHEN date_diff('year', m.birth_date, v.valid_from) < 50 THEN '35-49'
        WHEN date_diff('year', m.birth_date, v.valid_from) < 65 THEN '50-64'
        WHEN date_diff('year', m.birth_date, v.valid_from) < 80 THEN '65-79'
        ELSE '80+'
    END AS age_band,
    p.payer_key,
    p.payer_name
FROM versions v
JOIN stg.member m USING (member_id)
JOIN mart.dim_payer p ON p.payer_id = v.payer_id;

INSERT INTO mart.dim_member VALUES
    (-1, 'UNKNOWN', 'UNKNOWN', 0, DATE '1900-01-01', DATE '9999-12-31', TRUE,
     NULL, NULL, 'U', NULL, NULL, NULL, 'Unknown', -1, 'Unknown payer');
