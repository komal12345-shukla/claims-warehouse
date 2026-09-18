"""
Synthetic healthcare claims generator.

Emits CSVs that are column-compatible with a Synthea CSV export, so the rest of
this project runs unchanged against real Synthea output: drop Synthea's CSVs
into data/raw/ and skip this script.

What it deliberately models, because the reporting layer depends on it:

  * Claim lag. Service date and paid date are different, the gap is skewed with
    a long tail, and inpatient lags longer than outpatient. Without this a
    runout triangle has nothing to show.
  * Denials and contractual adjustments, so paid amount never equals charge.
  * Enrollment spans with gaps and payer switches, which is what member months
    and the Type 2 member dimension are built from.
  * Medication fills with adherence gaps, so PDC is not trivially 1.0.

Deterministic: same seed gives the same data.
"""

from __future__ import annotations

import argparse
import csv
import math
import random
import uuid
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path

# --------------------------------------------------------------------------
# reference data
# --------------------------------------------------------------------------

PAYERS = [
    ("Pacific Blue Shield", "PRIVATE"),
    ("Cascadia Health Plan", "PRIVATE"),
    ("Northstar Mutual", "PRIVATE"),
    ("State Medicaid Program", "GOVERNMENT"),
    ("Federal Medicare Program", "GOVERNMENT"),
]

ORGANIZATIONS = [
    ("Riverbend General Hospital", "Springfield", "Shelbyville"),
    ("Lakeside Medical Center", "Shelbyville", "Springfield"),
    ("Cedar Hill Family Practice", "Cedar Hill", "Springfield"),
    ("Harbourview Specialty Clinic", "Harbourview", "Shelbyville"),
    ("Mill Creek Urgent Care", "Mill Creek", "Cedar Hill"),
]

SPECIALTIES = [
    "GENERAL PRACTICE",
    "INTERNAL MEDICINE",
    "CARDIOLOGY",
    "ORTHOPEDIC SURGERY",
    "EMERGENCY MEDICINE",
    "ENDOCRINOLOGY",
    "NEPHROLOGY",
]

# encounter class -> (weight, base cost range, lag profile mean/sigma in days)
ENCOUNTER_CLASSES = {
    "ambulatory":  (0.46, (85, 420),    (2.9, 0.55)),
    "wellness":    (0.16, (120, 260),   (2.8, 0.50)),
    "outpatient":  (0.15, (240, 1_800), (3.1, 0.62)),
    "urgentcare":  (0.10, (180, 900),   (3.0, 0.58)),
    "emergency":   (0.08, (900, 6_500), (3.4, 0.70)),
    "inpatient":   (0.05, (4_200, 48_000), (3.9, 0.80)),
}

PROCEDURES = [
    ("99213", "Office visit, established patient, low complexity"),
    ("99214", "Office visit, established patient, moderate complexity"),
    ("99285", "Emergency department visit, high severity"),
    ("80053", "Comprehensive metabolic panel"),
    ("85025", "Complete blood count with differential"),
    ("93000", "Electrocardiogram, routine with interpretation"),
    ("71046", "Radiologic examination, chest, 2 views"),
    ("36415", "Collection of venous blood by venipuncture"),
    ("99223", "Initial hospital inpatient care, high complexity"),
    ("27447", "Total knee arthroplasty"),
]

DIAGNOSES = [
    ("E11.9",  "Type 2 diabetes mellitus without complications"),
    ("I10",    "Essential (primary) hypertension"),
    ("J44.9",  "Chronic obstructive pulmonary disease, unspecified"),
    ("M17.11", "Unilateral primary osteoarthritis, right knee"),
    ("N18.3",  "Chronic kidney disease, stage 3"),
    ("I50.9",  "Heart failure, unspecified"),
    ("F32.9",  "Major depressive disorder, single episode, unspecified"),
    ("Z00.00", "Encounter for general adult medical examination"),
]

# maintenance drugs: adherence is measurable because they are meant to be
# taken continuously
DRUGS = [
    ("860975", "Metformin hydrochloride 500 MG oral tablet", 34.0),
    ("314076", "Lisinopril 10 MG oral tablet", 12.5),
    ("197361", "Amlodipine 5 MG oral tablet", 14.0),
    ("617314", "Atorvastatin 40 MG oral tablet", 22.0),
    ("310798", "Levothyroxine sodium 75 MCG oral tablet", 18.5),
]

CITIES = ["Springfield", "Shelbyville", "Cedar Hill", "Harbourview", "Mill Creek"]

DENIAL_REASONS = [
    "CO-16 Claim lacks information",
    "CO-97 Benefit included in another service",
    "CO-29 Time limit for filing expired",
    "CO-50 Not deemed a medical necessity",
    "PR-204 Service not covered under plan",
]


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def new_id(rng: random.Random) -> str:
    return str(uuid.UUID(int=rng.getrandbits(128), version=4))


def weighted_choice(rng: random.Random, options: dict):
    keys = list(options)
    weights = [options[k][0] for k in keys]
    return rng.choices(keys, weights=weights, k=1)[0]


def lognormal_days(rng: random.Random, mu: float, sigma: float, cap: int) -> int:
    """Claim lag in days. Log-normal is the standard shape for this: most claims
    land inside a month, a stubborn tail runs for a year."""
    value = math.exp(rng.gauss(mu, sigma))
    return max(1, min(int(round(value)), cap))


def month_start(d: date) -> date:
    return date(d.year, d.month, 1)


def add_months(d: date, n: int) -> date:
    total = (d.year * 12 + (d.month - 1)) + n
    return date(total // 12, total % 12 + 1, 1)


def write_csv(path: Path, header: list[str], rows: list[list]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        w.writerows(rows)
    print(f"  {path.name:<28} {len(rows):>8,} rows")


@dataclass
class Member:
    id: str
    birthdate: date
    deathdate: date | None
    gender: str
    city: str
    state: str
    zipcode: str
    chronic: list[str]


# --------------------------------------------------------------------------
# generation
# --------------------------------------------------------------------------

def generate(out_dir: Path, n_patients: int, start: date, end: date, seed: int) -> None:
    rng = random.Random(seed)

    print(f"\nGenerating {n_patients:,} members, {start} to {end}, seed {seed}\n")

    # ---- payers -----------------------------------------------------------
    payer_ids = {}
    payer_rows = []
    for name, ownership in PAYERS:
        pid = new_id(rng)
        payer_ids[name] = pid
        payer_rows.append([pid, name, ownership])
    write_csv(out_dir / "payers.csv", ["Id", "NAME", "OWNERSHIP"], payer_rows)

    # ---- organizations ----------------------------------------------------
    org_rows = []
    org_ids = []
    for name, city, _ in ORGANIZATIONS:
        oid = new_id(rng)
        org_ids.append(oid)
        org_rows.append([oid, name, city, "BC", f"V{rng.randint(1,9)}{rng.choice('ABCEGHJ')} {rng.randint(1,9)}{rng.choice('ABCEGHJ')}{rng.randint(1,9)}"])
    write_csv(out_dir / "organizations.csv", ["Id", "NAME", "CITY", "STATE", "ZIP"], org_rows)

    # ---- providers --------------------------------------------------------
    provider_rows = []
    providers_by_org: dict[str, list[str]] = {o: [] for o in org_ids}
    for oid in org_ids:
        for _ in range(rng.randint(6, 11)):
            pid = new_id(rng)
            providers_by_org[oid].append(pid)
            provider_rows.append([
                pid, oid,
                f"Provider {len(provider_rows) + 1:03d}",
                rng.choice(SPECIALTIES),
            ])
    write_csv(out_dir / "providers.csv", ["Id", "ORGANIZATION", "NAME", "SPECIALITY"], provider_rows)

    # ---- members ----------------------------------------------------------
    members: list[Member] = []
    patient_rows = []
    for _ in range(n_patients):
        age = min(94, max(0, int(rng.gauss(47, 21))))
        birth = date(end.year - age, rng.randint(1, 12), rng.randint(1, 28))
        # ~1.5% of the panel dies inside the window, which is what makes
        # member-month denominators non-trivial
        death = None
        if rng.random() < 0.015:
            span = (end - start).days
            death = start + timedelta(days=rng.randint(span // 3, span))
        chronic = [c for c, _ in DIAGNOSES[:6] if rng.random() < 0.18]
        m = Member(
            id=new_id(rng),
            birthdate=birth,
            deathdate=death,
            gender=rng.choice(["M", "F"]),
            city=rng.choice(CITIES),
            state="BC",
            zipcode=f"V{rng.randint(1,9)}{rng.choice('ABCEGHJ')} {rng.randint(1,9)}{rng.choice('ABCEGHJ')}{rng.randint(1,9)}",
            chronic=chronic,
        )
        members.append(m)
        patient_rows.append([
            m.id, m.birthdate.isoformat(),
            m.deathdate.isoformat() if m.deathdate else "",
            m.gender, m.city, m.state, m.zipcode,
        ])
    write_csv(
        out_dir / "patients.csv",
        ["Id", "BIRTHDATE", "DEATHDATE", "GENDER", "CITY", "STATE", "ZIP"],
        patient_rows,
    )

    # ---- enrollment spans (payer transitions) -----------------------------
    # Each member holds coverage for one or more spans. Some switch payers,
    # some have an uncovered gap. This table is the source for both member
    # months and the Type 2 member dimension.
    transitions = []
    coverage: dict[str, list[tuple[date, date, str]]] = {}
    for m in members:
        cursor = start if rng.random() < 0.8 else start + timedelta(days=rng.randint(0, 400))
        member_end = min(end, m.deathdate or end)
        spans: list[tuple[date, date, str]] = []
        while cursor < member_end:
            payer_name = rng.choices(
                [p[0] for p in PAYERS],
                weights=[0.26, 0.22, 0.18, 0.20, 0.14],
                k=1,
            )[0]
            months = rng.choice([12, 12, 12, 18, 24, 24, 36])
            span_end = min(add_months(month_start(cursor), months) - timedelta(days=1), member_end)
            spans.append((cursor, span_end, payer_name))
            transitions.append([
                m.id,
                f"M{abs(hash(m.id + payer_name)) % 10**9:09d}",
                cursor.isoformat(),
                span_end.isoformat(),
                payer_ids[payer_name],
                dict(PAYERS)[payer_name],
            ])
            # 22% of switches leave an uncovered gap of 1-4 months
            gap = rng.randint(30, 120) if rng.random() < 0.22 else 1
            cursor = span_end + timedelta(days=gap)
        coverage[m.id] = spans
    write_csv(
        out_dir / "payer_transitions.csv",
        ["PATIENT", "MEMBERID", "START_DATE", "END_DATE", "PAYER", "OWNERSHIP"],
        transitions,
    )

    def payer_on(member_id: str, when: date) -> str | None:
        for s, e, name in coverage[member_id]:
            if s <= when <= e:
                return name
        return None

    # ---- encounters, claims, transactions, medications --------------------
    encounter_rows, claim_rows, txn_rows, med_rows = [], [], [], []
    total_days = (end - start).days

    for m in members:
        member_end = min(end, m.deathdate or end)
        if member_end <= start:
            continue

        # utilization rises with age and chronic burden
        age_at_start = (start - m.birthdate).days / 365.25
        base_rate = 1.6 + age_at_start / 22.0 + 2.1 * len(m.chronic)
        years = (member_end - start).days / 365.25
        n_enc = max(0, int(rng.gauss(base_rate * years, base_rate * years * 0.42)))

        for _ in range(n_enc):
            svc = start + timedelta(days=rng.randint(0, max(1, (member_end - start).days)))
            payer_name = payer_on(m.id, svc)
            if payer_name is None:
                continue  # uncovered: self-pay, out of scope for this warehouse

            ec = weighted_choice(rng, ENCOUNTER_CLASSES)
            _, cost_range, (mu, sigma) = ENCOUNTER_CLASSES[ec]

            org = rng.choice(org_ids)
            prov = rng.choice(providers_by_org[org])
            proc_code, proc_desc = rng.choice(PROCEDURES)
            diag_code, _ = rng.choice(
                [d for d in DIAGNOSES if d[0] in m.chronic] or DIAGNOSES
            )

            base_cost = round(rng.uniform(*cost_range), 2)
            units = 1 if ec != "inpatient" else rng.randint(1, 6)
            charge = round(base_cost * units, 2)

            # contractual adjustment: the payer's allowed amount is well under
            # billed charges, which is why "paid" and "billed" must be separate
            # measures in the fact table
            allowed_pct = rng.uniform(0.38, 0.72)
            allowed = round(charge * allowed_pct, 2)

            denied = rng.random() < 0.085
            if denied:
                paid = 0.0
                patient_resp = 0.0
                status = "DENIED"
            else:
                coinsurance = rng.choice([0.0, 0.0, 0.1, 0.2])
                paid = round(allowed * (1 - coinsurance), 2)
                patient_resp = round(allowed - paid, 2)
                status = "CLOSED"

            adjustment = round(charge - allowed, 2)

            lag = lognormal_days(rng, mu, sigma, cap=420)
            billed_date = svc + timedelta(days=rng.randint(0, 6))
            paid_date = svc + timedelta(days=lag)

            enc_id = new_id(rng)
            claim_id = new_id(rng)
            charge_id = rng.randint(10**7, 10**8 - 1)

            encounter_rows.append([
                enc_id, svc.isoformat(),
                (svc + timedelta(days=rng.randint(0, 5) if ec == "inpatient" else 0)).isoformat(),
                m.id, org, prov, payer_ids[payer_name], ec,
                proc_code, proc_desc,
                f"{base_cost:.2f}", f"{charge:.2f}", f"{paid:.2f}",
            ])

            claim_rows.append([
                claim_id, m.id, prov, payer_ids[payer_name], org, org,
                diag_code,
                svc.isoformat(), svc.isoformat(), status,
                f"{patient_resp:.2f}", billed_date.isoformat(),
                DENIAL_REASONS[rng.randrange(len(DENIAL_REASONS))] if denied else "",
            ])

            # CHARGE always posts on the service date
            txn_rows.append([
                new_id(rng), claim_id, charge_id, m.id, "CHARGE",
                f"{charge:.2f}", "", svc.isoformat(), svc.isoformat(),
                ec, proc_code, units, "0.00", "0.00", "0.00",
                f"{charge:.2f}", enc_id, prov,
            ])
            # ADJUSTMENT and PAYMENT post on the paid date: this gap is the lag
            txn_rows.append([
                new_id(rng), claim_id, charge_id, m.id, "ADJUSTMENT",
                f"{-adjustment:.2f}", "", paid_date.isoformat(), paid_date.isoformat(),
                ec, proc_code, units, "0.00", f"{adjustment:.2f}", "0.00",
                f"{allowed:.2f}", enc_id, prov,
            ])
            if not denied:
                txn_rows.append([
                    new_id(rng), claim_id, charge_id, m.id, "PAYMENT",
                    f"{-paid:.2f}", rng.choice(["ECHECK", "EFT", "CHECK"]),
                    paid_date.isoformat(), paid_date.isoformat(),
                    ec, proc_code, units, f"{paid:.2f}", "0.00", "0.00",
                    f"{patient_resp:.2f}", enc_id, prov,
                ])

        # ---- medication fills, for PDC -----------------------------------
        if m.chronic and rng.random() < 0.72:
            code, desc, unit_cost = rng.choice(DRUGS)
            # adherence: most members are decent, a real minority are not
            adherence = min(1.0, max(0.25, rng.betavariate(5.5, 2.4)))
            cursor = start + timedelta(days=rng.randint(0, 120))
            while cursor < member_end:
                days_supply = rng.choice([30, 30, 30, 90])
                stop = min(cursor + timedelta(days=days_supply), member_end)
                payer_name = payer_on(m.id, cursor)
                if payer_name:
                    total = round(unit_cost * (days_supply / 30), 2)
                    med_rows.append([
                        cursor.isoformat(), stop.isoformat(), m.id,
                        payer_ids[payer_name], "", code, desc,
                        f"{unit_cost:.2f}", f"{round(total * 0.8, 2):.2f}",
                        1, f"{total:.2f}", days_supply,
                    ])
                # the refill gap is what makes PDC less than 1
                gap = int(days_supply / adherence) - days_supply
                cursor = cursor + timedelta(days=days_supply + max(0, gap))

    write_csv(
        out_dir / "encounters.csv",
        ["Id", "START", "STOP", "PATIENT", "ORGANIZATION", "PROVIDER", "PAYER",
         "ENCOUNTERCLASS", "CODE", "DESCRIPTION", "BASE_ENCOUNTER_COST",
         "TOTAL_CLAIM_COST", "PAYER_COVERAGE"],
        encounter_rows,
    )
    write_csv(
        out_dir / "claims.csv",
        ["Id", "PATIENTID", "PROVIDERID", "PRIMARYPATIENTINSURANCEID",
         "DEPARTMENTID", "PATIENTDEPARTMENTID", "DIAGNOSIS1",
         "CURRENTILLNESSDATE", "SERVICEDATE", "STATUS1", "OUTSTANDING1",
         "LASTBILLEDDATE1", "DENIALREASON"],
        claim_rows,
    )
    write_csv(
        out_dir / "claims_transactions.csv",
        ["Id", "CLAIMID", "CHARGEID", "PATIENTID", "TYPE", "AMOUNT", "METHOD",
         "FROMDATE", "TODATE", "PLACEOFSERVICE", "PROCEDURECODE", "UNITS",
         "PAYMENTS", "ADJUSTMENTS", "TRANSFERS", "OUTSTANDING", "APPOINTMENTID",
         "PROVIDERID"],
        txn_rows,
    )
    write_csv(
        out_dir / "medications.csv",
        ["START", "STOP", "PATIENT", "PAYER", "ENCOUNTER", "CODE", "DESCRIPTION",
         "BASE_COST", "PAYER_COVERAGE", "DISPENSES", "TOTALCOST", "DAYS_SUPPLY"],
        med_rows,
    )

    print(f"\nDone. CSVs written to {out_dir}\n")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="data/raw", help="output directory")
    ap.add_argument("--patients", type=int, default=2500)
    ap.add_argument("--start", default="2023-01-01")
    ap.add_argument("--end", default="2025-12-31")
    ap.add_argument("--seed", type=int, default=20260917)
    a = ap.parse_args()

    generate(
        Path(a.out),
        a.patients,
        date.fromisoformat(a.start),
        date.fromisoformat(a.end),
        a.seed,
    )


if __name__ == "__main__":
    main()
