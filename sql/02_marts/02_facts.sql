-- ---------------------------------------------------------------------------
-- Dimensional layer: fact tables
--
-- Three facts at three different grains, because the questions need them:
--
--   fact_claim_transaction   one row per financial transaction.
--                            Grain: transaction_id.
--                            The only place lag can be measured honestly,
--                            because it keeps service date and post date apart.
--
--   fact_claim_line          one row per claim, transactions rolled up.
--                            Grain: claim_id.
--                            What most reporting actually reads.
--
--   fact_member_month        one row per member per month per payer.
--                            Grain: member_key, month_key.
--                            A periodic snapshot. This is the denominator for
--                            PMPM; counting distinct members instead of member
--                            months is the classic way to get PMPM wrong.
-- ---------------------------------------------------------------------------

-- ---- fact_claim_transaction ------------------------------------------------

CREATE OR REPLACE TABLE mart.fact_claim_transaction AS
SELECT
    t.transaction_id,
    t.claim_id,
    COALESCE(dm.member_key, -1)       AS member_key,
    COALESCE(dpay.payer_key, -1)      AS payer_key,
    COALESCE(dprov.provider_key, -1)  AS provider_key,
    COALESCE(dorg.organization_key, -1) AS organization_key,
    COALESCE(dproc.procedure_key, -1) AS procedure_key,
    COALESCE(dec.encounter_class_key, -1) AS encounter_class_key,
    CAST(strftime(c.service_date, '%Y%m%d') AS INTEGER) AS service_date_key,
    CAST(strftime(t.post_date,    '%Y%m%d') AS INTEGER) AS post_date_key,
    CAST(strftime(c.service_date, '%Y%m') AS INTEGER)   AS incurred_month_key,
    CAST(strftime(t.post_date,    '%Y%m') AS INTEGER)   AS paid_month_key,
    t.transaction_type,
    -- lag in whole months between the month of service and the month the money
    -- moved. 0 means same month. This is the triangle's column index.
    (EXTRACT(year FROM t.post_date) - EXTRACT(year FROM c.service_date)) * 12
        + (EXTRACT(month FROM t.post_date) - EXTRACT(month FROM c.service_date)) AS lag_months,
    date_diff('day', c.service_date, t.post_date) AS lag_days,
    t.units,
    t.charge_amount,
    t.paid_amount,
    t.adjusted_amount
FROM stg.claim_transaction t
JOIN stg.claim c              ON c.claim_id = t.claim_id
LEFT JOIN mart.dim_member dm  ON dm.member_id = c.member_id
                             AND c.service_date BETWEEN dm.valid_from AND dm.valid_to
LEFT JOIN mart.dim_payer dpay ON dpay.payer_id = c.payer_id
LEFT JOIN mart.dim_provider dprov ON dprov.provider_id = t.provider_id
LEFT JOIN mart.dim_organization dorg ON dorg.organization_id = c.organization_id
LEFT JOIN mart.dim_procedure dproc ON dproc.procedure_code = t.procedure_code
LEFT JOIN stg.encounter e     ON e.encounter_id = t.encounter_id
LEFT JOIN mart.dim_encounter_class dec ON dec.encounter_class = e.encounter_class;

-- ---- fact_claim_line -------------------------------------------------------

CREATE OR REPLACE TABLE mart.fact_claim_line AS
WITH rolled AS (
    SELECT
        claim_id,
        -- the claim's encounter comes from its transactions, not from matching
        -- on member and date: a member can have two encounters on one day, and
        -- joining on the date fans the claim out into duplicates. The
        -- reconciliation test in tests/run_tests.py exists because this is
        -- exactly the mistake that is invisible until totals are compared.
        ANY_VALUE(encounter_id) AS encounter_id,
        SUM(charge_amount)   AS billed_amount,
        SUM(paid_amount)     AS paid_amount,
        SUM(adjusted_amount) AS adjusted_amount,
        MAX(units)           AS units,
        -- the claim is "complete" on the date of its last money movement
        MAX(CASE WHEN transaction_type IN ('PAYMENT', 'ADJUSTMENT') THEN post_date END) AS settled_date
    FROM stg.claim_transaction
    GROUP BY claim_id
)
SELECT
    c.claim_id,
    COALESCE(dm.member_key, -1)           AS member_key,
    COALESCE(dpay.payer_key, -1)          AS payer_key,
    COALESCE(dprov.provider_key, -1)      AS provider_key,
    COALESCE(dorg.organization_key, -1)   AS organization_key,
    COALESCE(ddiag.diagnosis_key, -1)     AS diagnosis_key,
    COALESCE(dec.encounter_class_key, -1) AS encounter_class_key,
    CAST(strftime(c.service_date, '%Y%m%d') AS INTEGER) AS service_date_key,
    CAST(strftime(c.billed_date,  '%Y%m%d') AS INTEGER) AS billed_date_key,
    COALESCE(CAST(strftime(r.settled_date, '%Y%m%d') AS INTEGER), -1) AS settled_date_key,
    CAST(strftime(c.service_date, '%Y%m') AS INTEGER)   AS incurred_month_key,
    c.claim_status,
    c.denial_reason,
    c.claim_status = 'DENIED' AS is_denied,
    r.units,
    r.billed_amount,
    -- allowed = what the payer agreed to, i.e. billed net of the contractual
    -- write-off. Kept as its own measure because denial analysis needs it.
    r.billed_amount - r.adjusted_amount AS allowed_amount,
    r.paid_amount,
    r.adjusted_amount,
    c.patient_responsibility,
    date_diff('day', c.service_date, r.settled_date) AS settle_lag_days
FROM stg.claim c
JOIN rolled r USING (claim_id)
LEFT JOIN mart.dim_member dm  ON dm.member_id = c.member_id
                             AND c.service_date BETWEEN dm.valid_from AND dm.valid_to
LEFT JOIN mart.dim_payer dpay ON dpay.payer_id = c.payer_id
LEFT JOIN mart.dim_provider dprov ON dprov.provider_id = c.provider_id
LEFT JOIN mart.dim_organization dorg ON dorg.organization_id = c.organization_id
LEFT JOIN mart.dim_diagnosis ddiag ON ddiag.diagnosis_code = c.diagnosis_code
LEFT JOIN stg.encounter e ON e.encounter_id = r.encounter_id
LEFT JOIN mart.dim_encounter_class dec ON dec.encounter_class = e.encounter_class;

-- ---- fact_member_month -----------------------------------------------------
--
-- A member contributes one member month for every month in which coverage was
-- in force. Partial months count: a member enrolled from the 20th still
-- contributes that month, which matches how PMPM is conventionally reported.
-- A member who dies mid-window stops contributing.

CREATE OR REPLACE TABLE mart.fact_member_month AS
WITH months AS (
    SELECT DISTINCT month_key, month_start_date, month_end_date, year_month
    FROM mart.dim_date
    WHERE date_key <> -1
),
spans AS (
    SELECT
        dm.member_key,
        dm.member_id,
        dm.payer_key,
        dm.age_band,
        dm.gender,
        dm.valid_from,
        LEAST(dm.valid_to, COALESCE(dm.death_date, DATE '9999-12-31')) AS valid_to
    FROM mart.dim_member dm
    WHERE dm.member_key <> -1
)
SELECT
    s.member_key,
    s.member_id,
    s.payer_key,
    m.month_key,
    m.year_month,
    s.age_band,
    s.gender,
    1 AS member_months,
    -- days of coverage inside the month, for anyone who needs a fractional
    -- exposure rather than the whole-month convention
    date_diff('day',
              GREATEST(s.valid_from, m.month_start_date),
              LEAST(s.valid_to, m.month_end_date)) + 1 AS covered_days,
    date_diff('day', m.month_start_date, m.month_end_date) + 1 AS days_in_month
FROM spans s
JOIN months m
  ON s.valid_from <= m.month_end_date
 AND s.valid_to   >= m.month_start_date;
