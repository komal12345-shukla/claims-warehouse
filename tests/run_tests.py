"""
Data quality tests.

Each test is a SQL query that must return zero rows. Anything it does return is
printed, so a failure tells you which records broke the rule rather than just
that something did.

Three kinds of check, and all three earn their place:

  * Structural   - keys are unique, facts join to dimensions, no orphans.
  * Temporal     - Type 2 versions do not overlap and do not leave gaps that
                   would silently drop a claim on the join.
  * Reconciling  - the fact tables still add up to the source. This is the one
                   that catches a wrong join before it reaches a report.
"""

from __future__ import annotations

import sys

TESTS: list[tuple[str, str]] = [
    # ---- structural --------------------------------------------------------
    (
        "claim_id is unique in fact_claim_line",
        """
        SELECT claim_id, COUNT(*) AS n
        FROM mart.fact_claim_line
        GROUP BY claim_id HAVING COUNT(*) > 1
        """,
    ),
    (
        "transaction_id is unique in fact_claim_transaction",
        """
        SELECT transaction_id, COUNT(*) AS n
        FROM mart.fact_claim_transaction
        GROUP BY transaction_id HAVING COUNT(*) > 1
        """,
    ),
    (
        "member_key + month_key is unique in fact_member_month",
        """
        SELECT member_key, month_key, COUNT(*) AS n
        FROM mart.fact_member_month
        GROUP BY member_key, month_key HAVING COUNT(*) > 1
        """,
    ),
    (
        "every fact_claim_line payer_key exists in dim_payer",
        """
        SELECT DISTINCT f.payer_key
        FROM mart.fact_claim_line f
        LEFT JOIN mart.dim_payer d USING (payer_key)
        WHERE d.payer_key IS NULL
        """,
    ),
    (
        "every fact_claim_line member_key exists in dim_member",
        """
        SELECT DISTINCT f.member_key
        FROM mart.fact_claim_line f
        LEFT JOIN mart.dim_member d USING (member_key)
        WHERE d.member_key IS NULL
        """,
    ),
    (
        "no claim fell through to the unknown member",
        """
        SELECT COUNT(*) AS unmatched_claims
        FROM mart.fact_claim_line
        WHERE member_key = -1
        HAVING COUNT(*) > 0
        """,
    ),
    # ---- temporal ----------------------------------------------------------
    (
        "dim_member Type 2 versions do not overlap",
        """
        SELECT a.member_id, a.version_number, b.version_number
        FROM mart.dim_member a
        JOIN mart.dim_member b
          ON  a.member_id = b.member_id
          AND a.version_number < b.version_number
          AND a.valid_to >= b.valid_from
        WHERE a.member_key <> -1
        """,
    ),
    (
        "exactly one current version per member in dim_member",
        """
        SELECT member_id, SUM(CASE WHEN is_current THEN 1 ELSE 0 END) AS current_versions
        FROM mart.dim_member
        WHERE member_key <> -1
        GROUP BY member_id
        HAVING SUM(CASE WHEN is_current THEN 1 ELSE 0 END) <> 1
        """,
    ),
    (
        "valid_from is never after valid_to",
        """
        SELECT member_key, valid_from, valid_to
        FROM mart.dim_member
        WHERE valid_from > valid_to
        """,
    ),
    (
        "no payment posts before its service date",
        """
        SELECT transaction_id, lag_days
        FROM mart.fact_claim_transaction
        WHERE lag_days < 0
        """,
    ),
    (
        "no member month falls outside that member's coverage span",
        """
        SELECT mm.member_key, mm.month_key
        FROM mart.fact_member_month mm
        JOIN mart.dim_member dm USING (member_key)
        WHERE mm.covered_days <= 0
        """,
    ),
    # ---- reconciliation ----------------------------------------------------
    (
        "claim count reconciles: staging to fact",
        """
        SELECT
            (SELECT COUNT(*) FROM stg.claim)             AS staging_claims,
            (SELECT COUNT(*) FROM mart.fact_claim_line)  AS fact_claims
        HAVING staging_claims <> fact_claims
        """,
    ),
    (
        "billed dollars reconcile: raw transactions to fact_claim_line",
        """
        SELECT
            ROUND((SELECT SUM(amount) FROM raw.claims_transactions WHERE type = 'CHARGE'), 2) AS raw_billed,
            ROUND((SELECT SUM(billed_amount) FROM mart.fact_claim_line), 2)                   AS fact_billed
        HAVING ABS(raw_billed - fact_billed) > 0.01
        """,
    ),
    (
        "paid dollars reconcile: raw transactions to fact_claim_line",
        """
        SELECT
            ROUND((SELECT SUM(-amount) FROM raw.claims_transactions WHERE type = 'PAYMENT'), 2) AS raw_paid,
            ROUND((SELECT SUM(paid_amount) FROM mart.fact_claim_line), 2)                       AS fact_paid
        HAVING ABS(raw_paid - fact_paid) > 0.01
        """,
    ),
    (
        "paid dollars reconcile across both fact grains",
        """
        SELECT
            ROUND((SELECT SUM(paid_amount) FROM mart.fact_claim_line), 2)        AS line_grain,
            ROUND((SELECT SUM(paid_amount) FROM mart.fact_claim_transaction), 2) AS txn_grain
        HAVING ABS(line_grain - txn_grain) > 0.01
        """,
    ),
    (
        "member months reconcile to enrollment spans",
        """
        WITH expected AS (
            SELECT SUM(
                (EXTRACT(year  FROM LEAST(valid_to, DATE '2027-12-31'))
                 - EXTRACT(year  FROM valid_from)) * 12
              + (EXTRACT(month FROM LEAST(valid_to, DATE '2027-12-31'))
                 - EXTRACT(month FROM valid_from)) + 1
            ) AS n
            FROM mart.dim_member
            WHERE member_key <> -1
              AND LEAST(valid_to, COALESCE(death_date, DATE '9999-12-31')) >= valid_from
              AND death_date IS NULL
        )
        SELECT
            (SELECT n FROM expected) AS expected_months,
            (SELECT SUM(member_months) FROM mart.fact_member_month mm
             JOIN mart.dim_member dm USING (member_key)
             WHERE dm.death_date IS NULL) AS actual_months
        HAVING ABS(expected_months - actual_months) > 0
        """,
    ),
    # ---- business rules ----------------------------------------------------
    (
        "a denied claim never carries a payment",
        """
        SELECT claim_id, paid_amount
        FROM mart.fact_claim_line
        WHERE is_denied AND paid_amount <> 0
        """,
    ),
    (
        "allowed never exceeds billed",
        """
        SELECT claim_id, billed_amount, allowed_amount
        FROM mart.fact_claim_line
        WHERE allowed_amount > billed_amount + 0.01
        """,
    ),
    (
        "paid never exceeds allowed",
        """
        SELECT claim_id, allowed_amount, paid_amount
        FROM mart.fact_claim_line
        WHERE paid_amount > allowed_amount + 0.01
        """,
    ),
    (
        "PDC is always between 0 and 1",
        """
        SELECT member_id, drug_code, pdc
        FROM rpt_pdc_by_member_drug
        WHERE pdc < 0 OR pdc > 1
        """,
    ),
    (
        "completion factors are non-decreasing with lag",
        """
        SELECT lag_months, completion_factor, prev_factor
        FROM (
            SELECT
                lag_months,
                completion_factor,
                LAG(completion_factor) OVER (ORDER BY lag_months) AS prev_factor
            FROM rpt_completion_factors
        )
        WHERE prev_factor IS NOT NULL
          AND completion_factor < prev_factor - 0.0001
        """,
    ),
]


def execute_suite(con) -> int:
    failures = 0
    width = max(len(name) for name, _ in TESTS)
    for name, sql in TESTS:
        try:
            rows = con.execute(sql).fetchall()
        except Exception as exc:  # a broken test is a failed test
            print(f"  ERROR  {name.ljust(width)}  {exc}")
            failures += 1
            continue
        if rows:
            failures += 1
            print(f"  FAIL   {name.ljust(width)}  ({len(rows)} offending row(s))")
            for r in rows[:5]:
                print(f"           {r}")
        else:
            print(f"  pass   {name}")
    print(f"\n{len(TESTS) - failures}/{len(TESTS)} tests passed")
    return failures


if __name__ == "__main__":
    import duckdb
    from pathlib import Path

    db = Path(__file__).parent.parent / "out" / "claims.duckdb"
    if not db.exists():
        print("Build the warehouse first:  python run.py", file=sys.stderr)
        sys.exit(2)
    sys.exit(1 if execute_suite(duckdb.connect(str(db), read_only=True)) else 0)
