from __future__ import annotations

import argparse
import csv
import json
import sqlite3
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from app.persistence import QUOTE_OUTCOME_SCHEMA, SOFT_QUOTE_SCHEMA


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_DIR = (
    ROOT
    / "artifacts"
    / "modeling-research"
    / "pinnacle-prematch-forecast-soft-open"
)
PINNACLE_EXPORT = ARTIFACT_DIR / "pinnacle-final-quotes-by-line.csv"
RECONCILIATION = ARTIFACT_DIR / "soft-pinnacle-reconciliation.csv"


def _rscript_path() -> Path:
    candidates = (
        Path(r"C:\Program Files\R\R-4.6.1\bin\Rscript.exe"),
        Path("Rscript"),
    )
    for candidate in candidates:
        if candidate.is_absolute() and candidate.exists():
            return candidate
        if not candidate.is_absolute():
            return candidate
    raise FileNotFoundError("Rscript não encontrado.")


def _export_pinnacle() -> None:
    subprocess.run(
        [str(_rscript_path()), str(ROOT / "scripts" / "120_export_pinnacle_final_quotes.R")],
        cwd=ROOT,
        check=True,
    )


def _load_pinnacle() -> dict[tuple[str, float], dict[str, str]]:
    with PINNACLE_EXPORT.open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    return {
        (str(row["gameid"]), round(float(row["line"]), 6)): row
        for row in rows
    }


def reconcile(database_path: Path) -> list[dict[str, object]]:
    pinnacle = _load_pinnacle()
    results: list[dict[str, object]] = []
    with sqlite3.connect(database_path) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute(SOFT_QUOTE_SCHEMA)
        connection.execute(QUOTE_OUTCOME_SCHEMA)
        soft_rows = connection.execute(
            "SELECT * FROM soft_quote_observations ORDER BY observed_at"
        ).fetchall()
        for soft in soft_rows:
            gameid = str(soft["gameid"] or "")
            closing = pinnacle.get((gameid, round(float(soft["line"]), 6)))
            result: dict[str, object] = {
                "quote_id": soft["quote_id"],
                "gameid": gameid,
                "soft_line": soft["line"],
                "matched": closing is not None,
                "reason": "same_gameid_and_line" if closing else "no_exact_gameid_line_match",
            }
            if closing is None:
                results.append(result)
                continue

            existing = connection.execute(
                "SELECT * FROM quote_outcomes WHERE quote_id = ?", (soft["quote_id"],)
            ).fetchone()
            outcome = dict(existing) if existing is not None else {
                "quote_id": soft["quote_id"],
                "execution_status": "pending",
                "executed_side": None,
                "requested_odds": None,
                "requested_stake": None,
                "accepted_odds": None,
                "accepted_stake": None,
                "settled_at": None,
                "profit": None,
                "notes": None,
            }
            side = outcome.get("executed_side")
            closing_odds = None
            if side == "over":
                closing_odds = float(closing["odds_over"])
            elif side == "under":
                closing_odds = float(closing["odds_under"])
            accepted_odds = outcome.get("accepted_odds")
            clv = (
                float(accepted_odds) / closing_odds - 1
                if accepted_odds is not None and closing_odds is not None
                else None
            )
            payload = {}
            if outcome.get("payload_json"):
                try:
                    payload = json.loads(str(outcome["payload_json"]))
                except json.JSONDecodeError:
                    payload = {}
            payload["pinnacle_reconciliation"] = closing
            values = (
                soft["quote_id"],
                datetime.now(timezone.utc).isoformat(),
                outcome.get("execution_status", "pending"),
                side,
                outcome.get("requested_odds"),
                outcome.get("requested_stake"),
                accepted_odds,
                outcome.get("accepted_stake"),
                outcome.get("settled_at"),
                outcome.get("profit"),
                closing["final_pinnacle_time"],
                float(closing["line"]),
                float(closing["odds_over"]),
                float(closing["odds_under"]),
                clv,
                outcome.get("notes"),
                json.dumps(payload, ensure_ascii=False, sort_keys=True),
            )
            connection.execute(
                """
                INSERT OR REPLACE INTO quote_outcomes (
                    quote_id, updated_at, execution_status, executed_side,
                    requested_odds, requested_stake, accepted_odds, accepted_stake,
                    settled_at, profit, final_pinnacle_time, final_pinnacle_line,
                    final_pinnacle_odds_over, final_pinnacle_odds_under, clv, notes,
                    payload_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                values,
            )
            result.update(
                final_pinnacle_time=closing["final_pinnacle_time"],
                final_pinnacle_line=float(closing["line"]),
                final_pinnacle_odds_over=float(closing["odds_over"]),
                final_pinnacle_odds_under=float(closing["odds_under"]),
                clv=clv,
            )
            results.append(result)
        connection.commit()
    return results


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Anexa a última Pinnacle prematch na mesma linha às cotações soft locais."
    )
    parser.add_argument(
        "--database",
        type=Path,
        default=ROOT / ".local" / "predictions.sqlite",
    )
    parser.add_argument("--skip-export", action="store_true")
    args = parser.parse_args()
    if not args.skip_export:
        _export_pinnacle()
    if not args.database.exists():
        raise FileNotFoundError(f"Banco local não encontrado: {args.database}")
    results = reconcile(args.database)
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    fields = [
        "quote_id", "gameid", "soft_line", "matched", "reason",
        "final_pinnacle_time", "final_pinnacle_line",
        "final_pinnacle_odds_over", "final_pinnacle_odds_under", "clv",
    ]
    with RECONCILIATION.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(results)
    matched = sum(bool(row["matched"]) for row in results)
    print(f"{matched}/{len(results)} cotações soft reconciliadas na mesma linha.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
