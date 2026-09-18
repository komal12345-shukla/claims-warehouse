-- ---------------------------------------------------------------------------
-- PMPM, utilization and denial reporting
--
-- PMPM means paid dollars divided by MEMBER MONTHS, not by distinct members.
-- The difference is not cosmetic: members join, leave and switch payers
-- mid-year, so a payer with 1,000 members on the books did not carry 12,000
-- months of exposure. Dividing by headcount understates cost per member and
-- makes plans with heavy churn look cheap.
-- ---------------------------------------------------------------------------

-- ---- exposure --------------------------------------------------------------

CREATE OR REPLACE VIEW rpt_member_months AS
SELECT
    mm.month_key,
    mm.year_month,
    dp.payer_key,
    dp.payer_name,
    dp.ownership,
    COUNT(*)                        AS member_months,
    COUNT(DISTINCT mm.member_id)    AS distinct_members,
    SUM(mm.covered_days)            AS covered_days
FROM mart.fact_member_month mm
JOIN mart.dim_payer dp USING (payer_key)
GROUP BY ALL;

-- ---- PMPM by payer and month -----------------------------------------------

CREATE OR REPLACE VIEW rpt_pmpm_by_payer_month AS
WITH claims AS (
    SELECT
        incurred_month_key AS month_key,
        payer_key,
        SUM(paid_amount)    AS paid_amount,
        SUM(billed_amount)  AS billed_amount,
        SUM(allowed_amount) AS allowed_amount,
        COUNT(*)            AS claim_count
    FROM mart.fact_claim_line
    GROUP BY ALL
)
SELECT
    e.year_month,
    e.payer_name,
    e.ownership,
    e.member_months,
    e.distinct_members,
    COALESCE(c.claim_count, 0) AS claim_count,
    ROUND(COALESCE(c.paid_amount, 0), 2) AS paid_amount,
    ROUND(COALESCE(c.paid_amount, 0) / NULLIF(e.member_months, 0), 2) AS pmpm_paid,
    ROUND(COALESCE(c.allowed_amount, 0) / NULLIF(e.member_months, 0), 2) AS pmpm_allowed,
    ROUND(COALESCE(c.billed_amount, 0) / NULLIF(e.member_months, 0), 2) AS pmpm_billed,
    ROUND(COALESCE(c.claim_count, 0) * 1000.0 / NULLIF(e.member_months, 0), 1) AS claims_per_1000_member_months
    -- at monthly grain member months and headcount are the same number, so the
    -- correct and naive denominators agree here. See rpt_pmpm_annual_by_payer
    -- for the annual view, where they do not.
FROM rpt_member_months e
LEFT JOIN claims c ON c.month_key = e.month_key AND c.payer_key = e.payer_key
WHERE e.year_month BETWEEN '2023-01' AND '2025-12'
ORDER BY e.year_month, e.payer_name;

-- ---- PMPM by age band ------------------------------------------------------

CREATE OR REPLACE VIEW rpt_pmpm_by_age_band AS
WITH exposure AS (
    SELECT age_band, COUNT(*) AS member_months
    FROM mart.fact_member_month
    WHERE year_month BETWEEN '2023-01' AND '2025-12'
    GROUP BY age_band
),
cost AS (
    SELECT dm.age_band, SUM(f.paid_amount) AS paid_amount, COUNT(*) AS claim_count
    FROM mart.fact_claim_line f
    JOIN mart.dim_member dm USING (member_key)
    WHERE dm.member_key <> -1
    GROUP BY dm.age_band
)
SELECT
    e.age_band,
    e.member_months,
    COALESCE(c.claim_count, 0) AS claim_count,
    ROUND(COALESCE(c.paid_amount, 0), 2) AS paid_amount,
    ROUND(COALESCE(c.paid_amount, 0) / NULLIF(e.member_months, 0), 2) AS pmpm_paid
FROM exposure e
LEFT JOIN cost c USING (age_band)
ORDER BY e.age_band;

-- ---- denial and contractual adjustment rates -------------------------------

CREATE OR REPLACE VIEW rpt_denial_adjustment_rates AS
SELECT
    dec.setting,
    dec.encounter_class,
    COUNT(*) AS claims,
    SUM(CASE WHEN f.is_denied THEN 1 ELSE 0 END) AS denied_claims,
    ROUND(100.0 * SUM(CASE WHEN f.is_denied THEN 1 ELSE 0 END) / COUNT(*), 2) AS denial_rate_pct,
    ROUND(SUM(f.billed_amount), 2)  AS billed_amount,
    ROUND(SUM(f.allowed_amount), 2) AS allowed_amount,
    ROUND(SUM(f.paid_amount), 2)    AS paid_amount,
    -- what proportion of billed charges is written off contractually
    ROUND(100.0 * SUM(f.adjusted_amount) / NULLIF(SUM(f.billed_amount), 0), 2) AS adjustment_rate_pct,
    -- what proportion of the agreed amount actually gets paid
    ROUND(100.0 * SUM(f.paid_amount) / NULLIF(SUM(f.allowed_amount), 0), 2) AS paid_to_allowed_pct
FROM mart.fact_claim_line f
JOIN mart.dim_encounter_class dec USING (encounter_class_key)
WHERE dec.encounter_class_key <> -1
GROUP BY ALL
ORDER BY denial_rate_pct DESC;

-- ---- top denial reasons ----------------------------------------------------

CREATE OR REPLACE VIEW rpt_denial_reasons AS
SELECT
    denial_reason,
    COUNT(*) AS denied_claims,
    ROUND(SUM(billed_amount), 2) AS billed_amount_denied,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_denials
FROM mart.fact_claim_line
WHERE is_denied
GROUP BY denial_reason
ORDER BY denied_claims DESC;

-- ---- high-cost members -----------------------------------------------------
-- The classic finding in any claims book: a very small share of members
-- accounts for a very large share of spend.

CREATE OR REPLACE VIEW rpt_member_cost_concentration AS
WITH per_member AS (
    SELECT dm.member_id, SUM(f.paid_amount) AS paid_amount
    FROM mart.fact_claim_line f
    JOIN mart.dim_member dm USING (member_key)
    WHERE dm.member_key <> -1
    GROUP BY dm.member_id
),
ranked AS (
    SELECT
        member_id,
        paid_amount,
        NTILE(100) OVER (ORDER BY paid_amount DESC) AS pct_rank
    FROM per_member
)
SELECT
    CASE
        WHEN pct_rank <= 1  THEN 'Top 1%'
        WHEN pct_rank <= 5  THEN 'Top 5%'
        WHEN pct_rank <= 10 THEN 'Top 10%'
        WHEN pct_rank <= 50 THEN 'Top 50%'
        ELSE 'Bottom 50%'
    END AS cohort,
    COUNT(*) AS members,
    ROUND(SUM(paid_amount), 2) AS paid_amount,
    ROUND(100.0 * SUM(paid_amount) / SUM(SUM(paid_amount)) OVER (), 2) AS pct_of_total_paid
FROM ranked
GROUP BY cohort
ORDER BY pct_of_total_paid DESC;

-- ---- annual PMPM, where the member-months point actually bites -------------
--
-- At monthly grain, member months and distinct members are the same number, so
-- the two denominators agree. Over a year they diverge sharply, because members
-- join, leave and switch plans partway through. This view puts the correct and
-- the naive calculation side by side so the size of the error is visible rather
-- than asserted.

CREATE OR REPLACE VIEW rpt_pmpm_annual_by_payer AS
WITH exposure AS (
    SELECT
        LEFT(mm.year_month, 4) AS calendar_year,
        dp.payer_name,
        COUNT(*)                     AS member_months,
        COUNT(DISTINCT mm.member_id) AS distinct_members
    FROM mart.fact_member_month mm
    JOIN mart.dim_payer dp USING (payer_key)
    WHERE mm.year_month BETWEEN '2023-01' AND '2025-12'
    GROUP BY 1, 2
),
cost AS (
    SELECT
        CAST(LEFT(CAST(f.incurred_month_key AS VARCHAR), 4) AS VARCHAR) AS calendar_year,
        dp.payer_name,
        SUM(f.paid_amount) AS paid_amount
    FROM mart.fact_claim_line f
    JOIN mart.dim_payer dp USING (payer_key)
    GROUP BY 1, 2
)
SELECT
    e.calendar_year,
    e.payer_name,
    e.member_months,
    e.distinct_members,
    ROUND(e.member_months * 1.0 / NULLIF(e.distinct_members, 0), 2) AS avg_months_per_member,
    ROUND(COALESCE(c.paid_amount, 0), 2) AS paid_amount,
    ROUND(COALESCE(c.paid_amount, 0) / NULLIF(e.member_months, 0), 2)    AS pmpm_correct,
    ROUND(COALESCE(c.paid_amount, 0) / NULLIF(e.distinct_members, 0), 2) AS per_member_naive,
    ROUND(100.0 * (COALESCE(c.paid_amount, 0) / NULLIF(e.distinct_members, 0)
                 - COALESCE(c.paid_amount, 0) / NULLIF(e.member_months, 0))
          / NULLIF(COALESCE(c.paid_amount, 0) / NULLIF(e.member_months, 0), 0), 1) AS naive_overstates_by_pct
FROM exposure e
LEFT JOIN cost c USING (calendar_year, payer_name)
ORDER BY e.calendar_year, e.payer_name;
