-- ---------------------------------------------------------------------------
-- Raw layer
--
-- Land the source CSVs with explicit types. Nothing is cleaned or renamed here:
-- the raw schema mirrors the Synthea export exactly, so that swapping the
-- synthetic generator for a real Synthea run changes nothing downstream.
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS raw;

CREATE OR REPLACE TABLE raw.patients AS
SELECT
    Id            AS id,
    CAST(BIRTHDATE AS DATE) AS birthdate,
    TRY_CAST(NULLIF(DEATHDATE, '') AS DATE) AS deathdate,
    GENDER        AS gender,
    CITY          AS city,
    STATE         AS state,
    ZIP           AS zip
FROM read_csv(getvariable('raw_dir') || '/patients.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.payers AS
SELECT Id AS id, NAME AS name, OWNERSHIP AS ownership
FROM read_csv(getvariable('raw_dir') || '/payers.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.organizations AS
SELECT Id AS id, NAME AS name, CITY AS city, STATE AS state, ZIP AS zip
FROM read_csv(getvariable('raw_dir') || '/organizations.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.providers AS
SELECT Id AS id, ORGANIZATION AS organization, NAME AS name, SPECIALITY AS speciality
FROM read_csv(getvariable('raw_dir') || '/providers.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.payer_transitions AS
SELECT
    PATIENT   AS patient,
    MEMBERID  AS memberid,
    CAST(START_DATE AS DATE) AS start_date,
    CAST(END_DATE   AS DATE) AS end_date,
    PAYER     AS payer,
    OWNERSHIP AS ownership
FROM read_csv(getvariable('raw_dir') || '/payer_transitions.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.encounters AS
SELECT
    Id AS id,
    CAST(START AS DATE) AS start,
    CAST(STOP  AS DATE) AS stop,
    PATIENT AS patient,
    ORGANIZATION AS organization,
    PROVIDER AS provider,
    PAYER AS payer,
    ENCOUNTERCLASS AS encounterclass,
    CODE AS code,
    DESCRIPTION AS description,
    CAST(BASE_ENCOUNTER_COST AS DECIMAL(14, 2)) AS base_encounter_cost,
    CAST(TOTAL_CLAIM_COST    AS DECIMAL(14, 2)) AS total_claim_cost,
    CAST(PAYER_COVERAGE      AS DECIMAL(14, 2)) AS payer_coverage
FROM read_csv(getvariable('raw_dir') || '/encounters.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.claims AS
SELECT
    Id AS id,
    PATIENTID AS patientid,
    PROVIDERID AS providerid,
    PRIMARYPATIENTINSURANCEID AS primarypatientinsuranceid,
    DEPARTMENTID AS departmentid,
    DIAGNOSIS1 AS diagnosis1,
    CAST(SERVICEDATE AS DATE) AS servicedate,
    STATUS1 AS status1,
    CAST(OUTSTANDING1 AS DECIMAL(14, 2)) AS outstanding1,
    CAST(LASTBILLEDDATE1 AS DATE) AS lastbilleddate1,
    NULLIF(DENIALREASON, '') AS denialreason
FROM read_csv(getvariable('raw_dir') || '/claims.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.claims_transactions AS
SELECT
    Id AS id,
    CLAIMID AS claimid,
    CHARGEID AS chargeid,
    PATIENTID AS patientid,
    TYPE AS type,
    CAST(AMOUNT AS DECIMAL(14, 2)) AS amount,
    NULLIF(METHOD, '') AS method,
    CAST(FROMDATE AS DATE) AS fromdate,
    CAST(TODATE   AS DATE) AS todate,
    PLACEOFSERVICE AS placeofservice,
    PROCEDURECODE AS procedurecode,
    CAST(UNITS AS INTEGER) AS units,
    CAST(PAYMENTS   AS DECIMAL(14, 2)) AS payments,
    CAST(ADJUSTMENTS AS DECIMAL(14, 2)) AS adjustments,
    CAST(OUTSTANDING AS DECIMAL(14, 2)) AS outstanding,
    APPOINTMENTID AS appointmentid,
    PROVIDERID AS providerid
FROM read_csv(getvariable('raw_dir') || '/claims_transactions.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw.medications AS
SELECT
    CAST(START AS DATE) AS start,
    TRY_CAST(NULLIF(STOP, '') AS DATE) AS stop,
    PATIENT AS patient,
    PAYER AS payer,
    CODE AS code,
    DESCRIPTION AS description,
    CAST(TOTALCOST AS DECIMAL(14, 2)) AS totalcost,
    CAST(DAYS_SUPPLY AS INTEGER) AS days_supply
FROM read_csv(getvariable('raw_dir') || '/medications.csv', header = true, all_varchar = true);
