-- ---------------------------------------------------------------------------
-- Claim lag, completion factors and IBNR
--
-- The problem: claims are incurred in one month and paid over the following
-- several. Any month's paid total is therefore incomplete, and the most recent
-- months are the most incomplete. Reporting raw paid amounts by incurred month
-- makes recent months look artificially cheap and produces a downward trend
-- that is not real.
--
-- The standard fix is a development triangle. Rows are incurred months, columns
-- are months of delay, cells are cumulative paid. Reading down a column shows
-- how consistently claims develop; reading across a row shows one month filling
-- in. Completion factors come from the column averages, and dividing a partial
-- month by its completion factor estimates where it will land. The gap between
-- that estimate and what has actually been paid is the IBNR reserve.
--
-- Everything here is anchored to a VALUATION DATE. That is not decoration: a
-- reserve is a statement about what is known on a particular day. Without a
-- cutoff the warehouse can see payments that had not happened yet, every month
-- looks fully developed, and IBNR collapses to zero. Change the date below to
-- re-run the whole analysis as at a different close.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW rpt_config AS
SELECT
    DATE '2025-12-31' AS valuation_date,
    CAST(strftime(DATE '2025-12-31', '%Y%m') AS INTEGER) AS valuation_month_key,
    12 AS maturity_months;   -- months after which a period is treated as developed

-- ---- incremental paid by incurred month and lag, as at the valuation date --

CREATE OR REPLACE VIEW rpt_claim_lag_detail AS
SELECT
    f.incurred_month_key,
    f.lag_months,
    SUM(f.paid_amount) AS paid_amount,
    COUNT(DISTINCT f.claim_id) AS claims_touched
FROM mart.fact_claim_transaction f, rpt_config c
WHERE f.transaction_type = 'PAYMENT'
  AND f.lag_months >= 0
  AND f.post_date_key <= CAST(strftime(c.valuation_date, '%Y%m%d') AS INTEGER)
GROUP BY f.incurred_month_key, f.lag_months;

-- ---- the triangle, cumulative ---------------------------------------------

CREATE OR REPLACE VIEW rpt_claim_lag_triangle AS
WITH grid AS (
    SELECT im.incurred_month_key, l.lag_months
    FROM (SELECT DISTINCT incurred_month_key FROM rpt_claim_lag_detail) im
    CROSS JOIN (SELECT UNNEST(generate_series(0, 12)) AS lag_months) l
),
filled AS (
    SELECT
        g.incurred_month_key,
        g.lag_months,
        COALESCE(d.paid_amount, 0) AS paid_amount
    FROM grid g
    LEFT JOIN rpt_claim_lag_detail d USING (incurred_month_key, lag_months)
)
SELECT
    f.incurred_month_key,
    f.lag_months,
    ROUND(f.paid_amount, 2) AS incremental_paid,
    ROUND(SUM(f.paid_amount) OVER (
        PARTITION BY f.incurred_month_key
        ORDER BY f.lag_months
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), 2) AS cumulative_paid,
    -- a cell in the lower-right of the triangle has not happened yet as at the
    -- valuation date. It is NULL, not zero, and must never be averaged.
    date_diff('month',
              strptime(CAST(f.incurred_month_key AS VARCHAR), '%Y%m'),
              (SELECT valuation_date FROM rpt_config)) >= f.lag_months AS is_observed
FROM filled f;

-- ---- completion factors ----------------------------------------------------
--
-- Fitted only on incurred months old enough to be fully developed as at the
-- valuation date. Using immature months to estimate maturity is circular, and
-- it is the most common error in a hand-rolled version of this.

CREATE OR REPLACE VIEW rpt_completion_factors AS
WITH mature AS (
    SELECT t.*
    FROM rpt_claim_lag_triangle t, rpt_config c
    WHERE date_diff('month',
                    strptime(CAST(t.incurred_month_key AS VARCHAR), '%Y%m'),
                    c.valuation_date) >= c.maturity_months
      AND t.is_observed
),
ultimate AS (
    SELECT incurred_month_key, MAX(cumulative_paid) AS ultimate_paid
    FROM mature
    GROUP BY incurred_month_key
    HAVING MAX(cumulative_paid) > 0
)
SELECT
    m.lag_months,
    COUNT(*) AS months_observed,
    ROUND(AVG(m.cumulative_paid / u.ultimate_paid), 4) AS completion_factor,
    ROUND(MIN(m.cumulative_paid / u.ultimate_paid), 4) AS completion_factor_min,
    ROUND(MAX(m.cumulative_paid / u.ultimate_paid), 4) AS completion_factor_max
FROM mature m
JOIN ultimate u USING (incurred_month_key)
GROUP BY m.lag_months
ORDER BY m.lag_months;

-- ---- IBNR estimate ---------------------------------------------------------
--
-- For each incurred month: what has been paid as at the valuation date, divided
-- by the completion factor for that month's age, gives the estimated ultimate.
-- The difference is the reserve that should be carried for claims incurred but
-- not yet reported or not yet paid.

CREATE OR REPLACE VIEW rpt_ibnr_estimate AS
WITH paid_to_date AS (
    SELECT
        f.incurred_month_key,
        SUM(f.paid_amount) AS paid_to_date,
        COUNT(DISTINCT f.claim_id) AS claims_paid
    FROM mart.fact_claim_transaction f, rpt_config c
    WHERE f.transaction_type = 'PAYMENT'
      AND f.post_date_key <= CAST(strftime(c.valuation_date, '%Y%m%d') AS INTEGER)
    GROUP BY f.incurred_month_key
),
aged AS (
    SELECT
        p.*,
        date_diff('month',
                  strptime(CAST(p.incurred_month_key AS VARCHAR), '%Y%m'),
                  c.valuation_date) AS months_developed,
        c.maturity_months
    FROM paid_to_date p, rpt_config c
)
SELECT
    a.incurred_month_key,
    a.months_developed,
    a.claims_paid,
    ROUND(a.paid_to_date, 2) AS paid_to_date,
    COALESCE(cf.completion_factor, 1.0) AS completion_factor,
    ROUND(a.paid_to_date / NULLIF(COALESCE(cf.completion_factor, 1.0), 0), 2) AS estimated_ultimate,
    ROUND(a.paid_to_date / NULLIF(COALESCE(cf.completion_factor, 1.0), 0) - a.paid_to_date, 2) AS ibnr_reserve,
    a.months_developed >= a.maturity_months AS is_developed
FROM aged a
LEFT JOIN rpt_completion_factors cf
       ON cf.lag_months = LEAST(a.months_developed, a.maturity_months)
ORDER BY a.incurred_month_key;

-- ---- lag distribution, for the operational view ---------------------------

CREATE OR REPLACE VIEW rpt_lag_distribution_by_class AS
SELECT
    dec.setting,
    dec.encounter_class,
    COUNT(*) AS payments,
    ROUND(AVG(f.lag_days), 1) AS mean_lag_days,
    MEDIAN(f.lag_days) AS median_lag_days,
    QUANTILE_CONT(f.lag_days, 0.90) AS p90_lag_days,
    QUANTILE_CONT(f.lag_days, 0.99) AS p99_lag_days,
    MAX(f.lag_days) AS max_lag_days
FROM mart.fact_claim_transaction f
JOIN mart.dim_encounter_class dec USING (encounter_class_key)
WHERE f.transaction_type = 'PAYMENT'
  AND dec.encounter_class_key <> -1
GROUP BY dec.setting, dec.encounter_class
ORDER BY mean_lag_days DESC;

-- ---- back-test -------------------------------------------------------------
--
-- This dataset is complete, which means the true ultimate for every incurred
-- month is knowable. A production warehouse never has that luxury, but a
-- portfolio one should use it: comparing the estimate made at the valuation
-- date against what actually settled is the only honest way to say whether the
-- completion factors are any good.

CREATE OR REPLACE VIEW rpt_ibnr_backtest AS
WITH actual AS (
    SELECT incurred_month_key, SUM(paid_amount) AS actual_ultimate
    FROM mart.fact_claim_transaction
    WHERE transaction_type = 'PAYMENT'
    GROUP BY incurred_month_key
)
SELECT
    e.incurred_month_key,
    e.months_developed,
    ROUND(e.paid_to_date, 2)       AS paid_at_valuation,
    ROUND(e.estimated_ultimate, 2) AS estimated_ultimate,
    ROUND(a.actual_ultimate, 2)    AS actual_ultimate,
    ROUND(e.estimated_ultimate - a.actual_ultimate, 2) AS error_dollars,
    ROUND(100.0 * (e.estimated_ultimate - a.actual_ultimate)
          / NULLIF(a.actual_ultimate, 0), 2) AS error_pct
FROM rpt_ibnr_estimate e
JOIN actual a USING (incurred_month_key)
WHERE NOT e.is_developed
ORDER BY e.incurred_month_key DESC;
