-- ---------------------------------------------------------------------------
-- Medication adherence: Proportion of Days Covered (PDC)
--
-- PDC is the measure CMS and most plans use for adherence, and the detail that
-- trips people up is overlap. If a member refills early, the surplus supply
-- carries forward; it does not count twice. So the numerator is DISTINCT days
-- covered, not the sum of days supplied.
--
-- Denominator convention used here: first fill date through the end of the
-- measurement year (or the member's last covered day, whichever is earlier).
-- Members with a single fill are excluded, since one fill cannot demonstrate
-- a pattern.
--
-- A PDC at or above 0.80 is the conventional adherence threshold.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW rpt_pdc_by_member_drug AS
WITH fills AS (
    SELECT
        f.member_id,
        f.drug_code,
        f.drug_desc,
        f.fill_date,
        f.days_supply,
        EXTRACT(year FROM f.fill_date) AS measurement_year
    FROM stg.medication_fill f
),
bounds AS (
    SELECT
        member_id,
        drug_code,
        ANY_VALUE(drug_desc) AS drug_desc,
        measurement_year,
        MIN(fill_date) AS first_fill_date,
        COUNT(*)       AS fill_count,
        SUM(days_supply) AS days_supplied,
        LEAST(make_date(CAST(measurement_year AS INTEGER), 12, 31), DATE '2025-12-31') AS period_end
    FROM fills
    GROUP BY member_id, drug_code, measurement_year
),
-- explode each fill into the days it covers, then count the distinct days so
-- that overlapping supply is not double counted
covered_days AS (
    SELECT DISTINCT
        f.member_id,
        f.drug_code,
        f.measurement_year,
        UNNEST(generate_series(
            f.fill_date,
            f.fill_date + (f.days_supply - 1) * INTERVAL 1 DAY,
            INTERVAL 1 DAY
        ))::DATE AS covered_date
    FROM fills f
),
counted AS (
    SELECT
        c.member_id,
        c.drug_code,
        c.measurement_year,
        COUNT(*) AS days_covered
    FROM covered_days c
    JOIN bounds b
      ON b.member_id = c.member_id
     AND b.drug_code = c.drug_code
     AND b.measurement_year = c.measurement_year
    WHERE c.covered_date BETWEEN b.first_fill_date AND b.period_end
    GROUP BY ALL
)
SELECT
    b.member_id,
    b.drug_code,
    b.drug_desc,
    b.measurement_year,
    b.fill_count,
    b.first_fill_date,
    b.period_end,
    date_diff('day', b.first_fill_date, b.period_end) + 1 AS days_in_period,
    c.days_covered,
    ROUND(
        LEAST(1.0, c.days_covered * 1.0
              / NULLIF(date_diff('day', b.first_fill_date, b.period_end) + 1, 0)),
        4
    ) AS pdc,
    LEAST(1.0, c.days_covered * 1.0
          / NULLIF(date_diff('day', b.first_fill_date, b.period_end) + 1, 0)) >= 0.80 AS is_adherent
FROM bounds b
JOIN counted c
  ON  c.member_id = b.member_id
  AND c.drug_code = b.drug_code
  AND c.measurement_year = b.measurement_year
WHERE b.fill_count > 1;

-- ---- adherence bands -------------------------------------------------------

CREATE OR REPLACE VIEW rpt_adherence_bands AS
WITH banded AS (
    SELECT
        measurement_year,
        CASE
            WHEN pdc >= 0.90 THEN '0.90 - 1.00  (high)'
            WHEN pdc >= 0.80 THEN '0.80 - 0.89  (adherent)'
            WHEN pdc >= 0.60 THEN '0.60 - 0.79  (partial)'
            WHEN pdc >= 0.40 THEN '0.40 - 0.59  (poor)'
            ELSE                  '0.00 - 0.39  (very poor)'
        END AS pdc_band
    FROM rpt_pdc_by_member_drug
),
counted AS (
    SELECT measurement_year, pdc_band, COUNT(*) AS member_drug_years
    FROM banded
    GROUP BY measurement_year, pdc_band
)
SELECT
    measurement_year,
    pdc_band,
    member_drug_years,
    ROUND(100.0 * member_drug_years
          / SUM(member_drug_years) OVER (PARTITION BY measurement_year), 2) AS pct_of_year
FROM counted
ORDER BY measurement_year, pdc_band DESC;

-- ---- adherence by drug -----------------------------------------------------

CREATE OR REPLACE VIEW rpt_adherence_by_drug AS
SELECT
    drug_desc,
    COUNT(*) AS member_drug_years,
    ROUND(AVG(pdc), 4) AS mean_pdc,
    MEDIAN(pdc) AS median_pdc,
    ROUND(100.0 * SUM(CASE WHEN is_adherent THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_adherent
FROM rpt_pdc_by_member_drug
GROUP BY drug_desc
ORDER BY pct_adherent DESC;
