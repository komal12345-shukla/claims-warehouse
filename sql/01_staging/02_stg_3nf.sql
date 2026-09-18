-- ---------------------------------------------------------------------------
-- Staging layer: third normal form
--
-- Purpose of this layer is integrity, not speed. Every entity gets one table,
-- every attribute depends on the whole key and nothing but the key, and the
-- reference data that was repeated as free text in the source (procedure
-- descriptions, diagnosis descriptions, encounter classes) is pulled out into
-- its own lookup table.
--
-- Constraints are declared rather than implied. DuckDB enforces PRIMARY KEY and
-- UNIQUE, so a duplicate in the source fails the build here rather than
-- silently doubling a measure three layers downstream.
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS stg;

-- ---- reference -------------------------------------------------------------

CREATE OR REPLACE TABLE stg.encounter_class (
    encounter_class VARCHAR PRIMARY KEY,
    setting         VARCHAR NOT NULL,
    is_acute        BOOLEAN NOT NULL
);
INSERT INTO stg.encounter_class VALUES
    ('ambulatory', 'Outpatient', FALSE),
    ('wellness',   'Outpatient', FALSE),
    ('outpatient', 'Outpatient', FALSE),
    ('urgentcare', 'Urgent',     TRUE),
    ('emergency',  'Emergency',  TRUE),
    ('inpatient',  'Inpatient',  TRUE);

CREATE OR REPLACE TABLE stg.procedure_ref (
    procedure_code VARCHAR PRIMARY KEY,
    procedure_desc VARCHAR NOT NULL
);
INSERT INTO stg.procedure_ref
SELECT code, ANY_VALUE(description)
FROM raw.encounters
GROUP BY code;

CREATE OR REPLACE TABLE stg.diagnosis_ref (
    diagnosis_code VARCHAR PRIMARY KEY,
    diagnosis_desc VARCHAR
);
INSERT INTO stg.diagnosis_ref
SELECT DISTINCT diagnosis1, NULL
FROM raw.claims
WHERE diagnosis1 IS NOT NULL;

-- ---- parties ---------------------------------------------------------------

CREATE OR REPLACE TABLE stg.member (
    member_id   VARCHAR PRIMARY KEY,
    birth_date  DATE NOT NULL,
    death_date  DATE,
    gender      VARCHAR NOT NULL,
    city        VARCHAR,
    province    VARCHAR,
    postal_code VARCHAR
);
INSERT INTO stg.member
SELECT id, birthdate, deathdate, gender, city, state, zip
FROM raw.patients;

CREATE OR REPLACE TABLE stg.payer (
    payer_id   VARCHAR PRIMARY KEY,
    payer_name VARCHAR NOT NULL,
    ownership  VARCHAR NOT NULL
);
INSERT INTO stg.payer SELECT id, name, ownership FROM raw.payers;

CREATE OR REPLACE TABLE stg.organization (
    organization_id   VARCHAR PRIMARY KEY,
    organization_name VARCHAR NOT NULL,
    city              VARCHAR,
    province          VARCHAR,
    postal_code       VARCHAR
);
INSERT INTO stg.organization SELECT id, name, city, state, zip FROM raw.organizations;

CREATE OR REPLACE TABLE stg.provider (
    provider_id     VARCHAR PRIMARY KEY,
    organization_id VARCHAR NOT NULL,
    provider_name   VARCHAR NOT NULL,
    specialty       VARCHAR
);
INSERT INTO stg.provider SELECT id, organization, name, speciality FROM raw.providers;

-- ---- enrollment ------------------------------------------------------------
-- One row per continuous coverage span. Gaps between spans are real: a member
-- with a gap contributes no member months for those months, which is the whole
-- reason PMPM cannot be computed from a simple headcount.

CREATE OR REPLACE TABLE stg.enrollment (
    enrollment_id  VARCHAR PRIMARY KEY,
    member_id      VARCHAR NOT NULL,
    payer_id       VARCHAR NOT NULL,
    member_number  VARCHAR NOT NULL,
    effective_date DATE NOT NULL,
    end_date       DATE NOT NULL
);
INSERT INTO stg.enrollment
SELECT
    md5(patient || '|' || payer || '|' || CAST(start_date AS VARCHAR)),
    patient, payer, memberid, start_date, end_date
FROM raw.payer_transitions;

-- ---- clinical and financial events ----------------------------------------

CREATE OR REPLACE TABLE stg.encounter (
    encounter_id    VARCHAR PRIMARY KEY,
    member_id       VARCHAR NOT NULL,
    organization_id VARCHAR NOT NULL,
    provider_id     VARCHAR NOT NULL,
    payer_id        VARCHAR NOT NULL,
    encounter_class VARCHAR NOT NULL,
    procedure_code  VARCHAR NOT NULL,
    start_date      DATE NOT NULL,
    stop_date       DATE,
    billed_amount   DECIMAL(14, 2) NOT NULL
);
INSERT INTO stg.encounter
SELECT id, patient, organization, provider, payer, encounterclass, code,
       start, stop, total_claim_cost
FROM raw.encounters;

CREATE OR REPLACE TABLE stg.claim (
    claim_id               VARCHAR PRIMARY KEY,
    member_id              VARCHAR NOT NULL,
    provider_id            VARCHAR NOT NULL,
    payer_id               VARCHAR NOT NULL,
    organization_id        VARCHAR NOT NULL,
    diagnosis_code         VARCHAR,
    service_date           DATE NOT NULL,
    billed_date            DATE NOT NULL,
    claim_status           VARCHAR NOT NULL,
    denial_reason          VARCHAR,
    patient_responsibility DECIMAL(14, 2) NOT NULL
);
INSERT INTO stg.claim
SELECT id, patientid, providerid, primarypatientinsuranceid, departmentid,
       diagnosis1, servicedate, lastbilleddate1, status1, denialreason,
       outstanding1
FROM raw.claims;

-- Transaction amounts are signed in the source (payments and adjustments post
-- negative against the charge). Flipping them here, once, means no downstream
-- query has to remember the convention.
CREATE OR REPLACE TABLE stg.claim_transaction (
    transaction_id   VARCHAR PRIMARY KEY,
    claim_id         VARCHAR NOT NULL,
    encounter_id     VARCHAR,
    provider_id      VARCHAR NOT NULL,
    transaction_type VARCHAR NOT NULL,
    post_date        DATE NOT NULL,
    procedure_code   VARCHAR NOT NULL,
    units            INTEGER NOT NULL,
    charge_amount    DECIMAL(14, 2) NOT NULL,
    paid_amount      DECIMAL(14, 2) NOT NULL,
    adjusted_amount  DECIMAL(14, 2) NOT NULL,
    payment_method   VARCHAR
);
INSERT INTO stg.claim_transaction
SELECT
    id, claimid, appointmentid, providerid, type, fromdate, procedurecode, units,
    CASE WHEN type = 'CHARGE'     THEN amount      ELSE 0 END,
    CASE WHEN type = 'PAYMENT'    THEN -amount     ELSE 0 END,
    CASE WHEN type = 'ADJUSTMENT' THEN -amount     ELSE 0 END,
    method
FROM raw.claims_transactions;

CREATE OR REPLACE TABLE stg.medication_fill (
    fill_id      VARCHAR PRIMARY KEY,
    member_id    VARCHAR NOT NULL,
    payer_id     VARCHAR NOT NULL,
    drug_code    VARCHAR NOT NULL,
    drug_desc    VARCHAR NOT NULL,
    fill_date    DATE NOT NULL,
    days_supply  INTEGER NOT NULL,
    total_cost   DECIMAL(14, 2) NOT NULL
);
INSERT INTO stg.medication_fill
SELECT
    md5(patient || '|' || code || '|' || CAST(start AS VARCHAR)),
    patient, payer, code, description, start, days_supply, totalcost
FROM raw.medications;
