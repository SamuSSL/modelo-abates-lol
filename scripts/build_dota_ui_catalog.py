from __future__ import annotations

import argparse
import csv
import hashlib
import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


FEATURE_NAMES = (
    "team_one_kills_for",
    "team_one_kills_against",
    "team_two_kills_for",
    "team_two_kills_against",
    "team_one_kills_for_recency_15d",
    "team_one_kills_against_recency_15d",
    "team_two_kills_for_recency_15d",
    "team_two_kills_against_recency_15d",
)


def _read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _float(value: str) -> float | None:
    if value is None or not value.strip():
        return None
    return float(value)


def build_catalog(dota_root: Path) -> dict[str, Any]:
    feature_path = dota_root / "data" / "features" / "point_in_time_features.csv"
    matching_path = dota_root / "data" / "interim" / "matching_targets_input.csv"
    tier_path = dota_root / "data" / "reference" / "competition_tier_decisions.csv"
    features = _read_csv(feature_path)
    matching = {
        row["opendota_match_id"]: row
        for row in _read_csv(matching_path)
        if row.get("review_status") == "accepted"
        and row.get("match_confidence") in {"exact", "high_confidence"}
    }
    tiers = {
        row["bic_league_id"]: row
        for row in _read_csv(tier_path)
        if row.get("tier") in {"S", "A"}
    }
    snapshots: list[dict[str, Any]] = []
    for feature_row in features:
        match_id = feature_row.get("opendota_match_id", "")
        market_row = matching.get(match_id)
        if market_row is None:
            continue
        tier_row = tiers.get(market_row.get("source_league_id", ""))
        if tier_row is None:
            continue
        team_one_id = feature_row.get("team_one_id", "").strip()
        team_two_id = feature_row.get("team_two_id", "").strip()
        team_one_name = market_row.get("team_one", "").strip()
        team_two_name = market_row.get("team_two", "").strip()
        if not team_one_id or not team_two_id or not team_one_name or not team_two_name:
            continue
        values = {name: _float(feature_row.get(name, "")) for name in FEATURE_NAMES}
        if any(value is None for value in values.values()):
            continue
        snapshots.append({
            "opendota_match_id": match_id,
            "opendota_series_id": feature_row.get("opendota_series_id", ""),
            "scheduled_start": feature_row.get("scheduled_start", ""),
            "source_league_id": market_row.get("source_league_id", ""),
            "league_name": tier_row.get("league_name", ""),
            "tier": tier_row.get("tier", ""),
            "opendota_league_id": feature_row.get("league_id", ""),
            "map_number": int(float(feature_row.get("map_number", "1") or 1)),
            "team_one_id": team_one_id,
            "team_two_id": team_two_id,
            "team_one_name": team_one_name,
            "team_two_name": team_two_name,
            "features": {name: float(value) for name, value in values.items()},
        })
    snapshots.sort(key=lambda row: (row["scheduled_start"], row["opendota_match_id"]))

    league_rows: dict[str, dict[str, Any]] = {}
    league_teams: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    for row in snapshots:
        league_id = row["source_league_id"]
        league_rows[league_id] = {
            "source_league_id": league_id,
            "league_name": row["league_name"],
            "tier": row["tier"],
        }
        for side in ("one", "two"):
            team_id = row[f"team_{side}_id"]
            team_name = row[f"team_{side}_name"]
            prior = league_teams[league_id].get(team_id)
            if prior is None or row["scheduled_start"] >= prior["last_seen"]:
                league_teams[league_id][team_id] = {
                    "team_id": team_id,
                    "team_name": team_name,
                    "last_seen": row["scheduled_start"],
                }
    leagues = []
    for league_id in sorted(league_rows, key=lambda value: (league_rows[value]["league_name"].casefold(), value)):
        league = dict(league_rows[league_id])
        league["teams"] = sorted(
            league_teams[league_id].values(),
            key=lambda row: (row["team_name"].casefold(), row["team_id"]),
        )
        leagues.append(league)
    return {
        "catalog_version": 1,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "feature_names": list(FEATURE_NAMES),
        "source": {
            "project": str(dota_root),
            "point_in_time_features_sha256": _sha256(feature_path),
            "matching_targets_input_sha256": _sha256(matching_path),
            "competition_tier_decisions_sha256": _sha256(tier_path),
        },
        "leagues": leagues,
        "snapshots": snapshots,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Build the portable Dota UI catalog from audited point-in-time data.")
    parser.add_argument("--dota-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    catalog = build_catalog(args.dota_root.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output.resolve()), "leagues": len(catalog["leagues"]), "snapshots": len(catalog["snapshots"])}, ensure_ascii=False))


if __name__ == "__main__":
    main()
