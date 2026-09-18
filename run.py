"""
Build the warehouse.

Executes every .sql file under sql/ in lexical order against a DuckDB database,
then runs the test suite. Exits non-zero if any test fails, so this is safe to
drop into CI.

    python run.py                 # build + test
    python run.py --skip-tests    # build only
    python run.py --report        # build + test + print the reporting tables
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).parent
SQL_DIR = ROOT / "sql"
DB_PATH = ROOT / "out" / "claims.duckdb"


def sql_files() -> list[Path]:
    return sorted(SQL_DIR.rglob("*.sql"), key=lambda p: str(p.relative_to(SQL_DIR)))


def build(con: duckdb.DuckDBPyConnection) -> None:
    for path in sql_files():
        rel = path.relative_to(SQL_DIR)
        t0 = time.perf_counter()
        try:
            con.execute(path.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"  FAILED  {rel}\n\n{exc}\n")
            raise
        print(f"  ok      {rel}  ({time.perf_counter() - t0:.2f}s)")


def run_tests(con: duckdb.DuckDBPyConnection) -> int:
    from tests.run_tests import execute_suite  # noqa: PLC0415

    return execute_suite(con)


def show_reports(con: duckdb.DuckDBPyConnection) -> None:
    views = [
        ("Claim lag triangle (incurred month x lag month, paid amount)", "rpt_claim_lag_triangle"),
        ("Lag completion factors", "rpt_completion_factors"),
        ("PMPM by payer and month", "rpt_pmpm_by_payer_month"),
        ("Denial and adjustment rates by encounter class", "rpt_denial_adjustment_rates"),
        ("Medication adherence (PDC) bands", "rpt_adherence_bands"),
    ]
    for title, view in views:
        print(f"\n### {title}\n")
        print(con.sql(f"SELECT * FROM {view} LIMIT 20").to_df().to_string(index=False))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-tests", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--db", default=str(DB_PATH))
    args = ap.parse_args()

    db = Path(args.db)
    db.parent.mkdir(parents=True, exist_ok=True)
    if db.exists():
        db.unlink()

    raw = ROOT / "data" / "raw"
    if not (raw / "claims.csv").exists():
        print(
            "No source data found in data/raw/.\n"
            "Run:  python generator/generate.py --out data/raw\n"
            "or drop a Synthea CSV export into that directory.",
            file=sys.stderr,
        )
        return 2

    print(f"\nBuilding {db}\n")
    con = duckdb.connect(str(db))
    con.execute(f"SET VARIABLE raw_dir = '{raw.as_posix()}'")
    build(con)

    failures = 0
    if not args.skip_tests:
        print()
        failures = run_tests(con)

    if args.report:
        show_reports(con)

    con.close()
    print()
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
