from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
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
HISTORY_SOURCE_LEAGUE_ID = "__opendota_history__"
HISTORY_LEAGUE_NAME = "Histórico OpenDota"
HISTORY_MIN_MAPS = 5
HISTORY_HALF_LIFE_DAYS = 15.0
HISTORY_SHRINKAGE_PRIOR = 5.0
HISTORY_TEAM_NAME_OVERRIDES = frozenset({"hokori", "lgd gaming"})


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


def _timestamp(value: str) -> datetime | None:
    if value is None or not value.strip():
        return None
    parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _shrink(value: float | None, count: int, prior: float | None) -> float | None:
    if value is None or not math.isfinite(value) or count <= 0:
        return prior
    if prior is None or not math.isfinite(prior):
        return value
    return (count * value + HISTORY_SHRINKAGE_PRIOR * prior) / (count + HISTORY_SHRINKAGE_PRIOR)


def _history_team_state() -> dict[str, float | int | datetime | None]:
    return {
        "for_sum": 0.0,
        "against_sum": 0.0,
        "count": 0,
        "recency_for_sum": 0.0,
        "recency_against_sum": 0.0,
        "recency_weight": 0.0,
        "last_timestamp": None,
    }


def _decay_history_state(state: dict[str, float | int | datetime | None], timestamp: datetime) -> None:
    last_timestamp = state["last_timestamp"]
    if isinstance(last_timestamp, datetime):
        age_days = max(0.0, (timestamp - last_timestamp).total_seconds() / 86400.0)
        factor = 2.0 ** (-age_days / HISTORY_HALF_LIFE_DAYS)
        state["recency_for_sum"] = float(state["recency_for_sum"]) * factor
        state["recency_against_sum"] = float(state["recency_against_sum"]) * factor
        state["recency_weight"] = float(state["recency_weight"]) * factor
    state["last_timestamp"] = timestamp


def _build_opendota_history_snapshots(
    canonical_path: Path,
    existing_team_ids: set[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    valid_rows: list[dict[str, Any]] = []
    team_counts: dict[str, int] = defaultdict(int)
    team_names: dict[str, str] = {}
    team_last_seen: dict[str, datetime] = {}
    with canonical_path.open("r", encoding="utf-8-sig", newline="") as handle:
        for raw in csv.DictReader(handle):
            timestamp = _timestamp(raw.get("effective_start", "") or raw.get("scheduled_start", ""))
            radiant_id = str(raw.get("radiant_team_id", "")).strip()
            dire_id = str(raw.get("dire_team_id", "")).strip()
            radiant_name = str(raw.get("radiant_name", "")).strip()
            dire_name = str(raw.get("dire_name", "")).strip()
            radiant_score = _float(raw.get("radiant_score", ""))
            dire_score = _float(raw.get("dire_score", ""))
            total_kills = _float(raw.get("fundamental_total_kills", ""))
            if (
                timestamp is None
                or not radiant_id
                or not dire_id
                or not radiant_name
                or not dire_name
                or radiant_score is None
                or dire_score is None
                or total_kills is None
            ):
                continue
            row = {
                "opendota_match_id": str(raw.get("opendota_match_id", "")).strip(),
                "opendota_series_id": str(raw.get("opendota_series_id", "")).strip()
                or str(raw.get("opendota_match_id", "")).strip(),
                "timestamp": timestamp,
                "league_id": str(raw.get("league_id", "")).strip() or "__unknown__",
                "map_number": int(float(raw.get("map_number", "1") or 1)),
                "radiant_id": radiant_id,
                "dire_id": dire_id,
                "radiant_name": radiant_name,
                "dire_name": dire_name,
                "radiant_score": radiant_score,
                "dire_score": dire_score,
                "total_kills": total_kills,
            }
            valid_rows.append(row)
            for team_id, team_name in ((radiant_id, radiant_name), (dire_id, dire_name)):
                team_counts[team_id] += 1
                if team_id not in team_names or timestamp >= team_last_seen[team_id]:
                    team_names[team_id] = team_name
                    team_last_seen[team_id] = timestamp

    history_team_ids = {
        team_id
        for team_id, count in team_counts.items()
        if team_id not in existing_team_ids
        and count >= HISTORY_MIN_MAPS
        and (
            team_names[team_id].casefold().startswith("team ")
            or team_names[team_id].casefold() in HISTORY_TEAM_NAME_OVERRIDES
        )
    }
    history_teams = [
        {
            "team_id": team_id,
            "team_name": team_names[team_id],
            "last_seen": team_last_seen[team_id].isoformat().replace("+00:00", "Z"),
            "map_count": team_counts[team_id],
            "source": "opendota_canonical",
            "history_only": True,
        }
        for team_id in sorted(history_team_ids, key=lambda value: (team_names[value].casefold(), value))
    ]
    if not history_team_ids:
        return history_teams, []

    by_series: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in valid_rows:
        by_series[row["opendota_series_id"]].append(row)
    series_groups = sorted(
        by_series.values(),
        key=lambda group: min(row["timestamp"] for row in group),
    )
    team_states: dict[str, dict[str, float | int | datetime | None]] = defaultdict(_history_team_state)
    league_states: dict[str, dict[str, float | int]] = defaultdict(lambda: {"sum": 0.0, "count": 0})
    global_sum = 0.0
    global_count = 0
    snapshots: list[dict[str, Any]] = []

    for group in series_groups:
        group = sorted(group, key=lambda row: (row["timestamp"], row["opendota_match_id"]))
        for row in group:
            timestamp = row["timestamp"]
            league_state = league_states[row["league_id"]]
            league_prior = (
                float(league_state["sum"]) / int(league_state["count"])
                if int(league_state["count"]) > 0
                else (global_sum / global_count if global_count > 0 else None)
            )
            values: dict[str, float] = {}
            for prefix, team_id, kills_for, kills_against in (
                ("team_one", row["radiant_id"], row["radiant_score"], row["dire_score"]),
                ("team_two", row["dire_id"], row["dire_score"], row["radiant_score"]),
            ):
                state = team_states[team_id]
                _decay_history_state(state, timestamp)
                count = int(state["count"])
                raw_for = float(state["for_sum"]) / count if count > 0 else None
                raw_against = float(state["against_sum"]) / count if count > 0 else None
                weighted_for = (
                    float(state["recency_for_sum"]) / float(state["recency_weight"])
                    if float(state["recency_weight"]) > 0
                    else None
                )
                weighted_against = (
                    float(state["recency_against_sum"]) / float(state["recency_weight"])
                    if float(state["recency_weight"]) > 0
                    else None
                )
                values[f"{prefix}_kills_for"] = _shrink(raw_for, count, league_prior)
                values[f"{prefix}_kills_against"] = _shrink(raw_against, count, league_prior)
                values[f"{prefix}_kills_for_recency_15d"] = _shrink(weighted_for, count, league_prior)
                values[f"{prefix}_kills_against_recency_15d"] = _shrink(weighted_against, count, league_prior)
            if (
                row["radiant_id"] in history_team_ids or row["dire_id"] in history_team_ids
            ) and all(math.isfinite(value) for value in values.values() if value is not None) and all(
                value is not None for value in values.values()
            ):
                snapshots.append({
                    "opendota_match_id": row["opendota_match_id"],
                    "opendota_series_id": row["opendota_series_id"],
                    "scheduled_start": timestamp.isoformat().replace("+00:00", "Z"),
                    "source_league_id": HISTORY_SOURCE_LEAGUE_ID,
                    "league_name": HISTORY_LEAGUE_NAME,
                    "tier": "",
                    "opendota_league_id": row["league_id"],
                    "map_number": row["map_number"],
                    "team_one_id": row["radiant_id"],
                    "team_two_id": row["dire_id"],
                    "team_one_name": row["radiant_name"],
                    "team_two_name": row["dire_name"],
                    "history_source": "opendota_canonical",
                    "features": {name: float(value) for name, value in values.items()},
                })

        for row in group:
            timestamp = row["timestamp"]
            for team_id, kills_for, kills_against in (
                (row["radiant_id"], row["radiant_score"], row["dire_score"]),
                (row["dire_id"], row["dire_score"], row["radiant_score"]),
            ):
                state = team_states[team_id]
                _decay_history_state(state, timestamp)
                state["for_sum"] = float(state["for_sum"]) + kills_for
                state["against_sum"] = float(state["against_sum"]) + kills_against
                state["count"] = int(state["count"]) + 1
                state["recency_for_sum"] = float(state["recency_for_sum"]) + kills_for
                state["recency_against_sum"] = float(state["recency_against_sum"]) + kills_against
                state["recency_weight"] = float(state["recency_weight"]) + 1.0
            league_state = league_states[row["league_id"]]
            league_state["sum"] = float(league_state["sum"]) + row["total_kills"]
            league_state["count"] = int(league_state["count"]) + 2
            global_sum += row["total_kills"]
            global_count += 2

    snapshots.sort(key=lambda row: (row["scheduled_start"], row["opendota_match_id"]))
    return history_teams, snapshots


def build_catalog(dota_root: Path) -> dict[str, Any]:
    feature_path = dota_root / "data" / "features" / "point_in_time_features.csv"
    matching_path = dota_root / "data" / "interim" / "matching_targets_input.csv"
    tier_path = dota_root / "data" / "reference" / "competition_tier_decisions.csv"
    canonical_path = dota_root / "data" / "canonical" / "opendota_matches.csv"
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
    existing_team_ids = {
        row[f"team_{side}_id"]
        for row in snapshots
        for side in ("one", "two")
        if row[f"team_{side}_id"]
    }
    market_snapshots = list(snapshots)
    history_teams, history_snapshots = _build_opendota_history_snapshots(canonical_path, existing_team_ids)
    snapshots.extend(history_snapshots)
    snapshots.sort(key=lambda row: (row["scheduled_start"], row["opendota_match_id"]))

    league_rows: dict[str, dict[str, Any]] = {}
    league_teams: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    for row in market_snapshots:
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
            "opendota_matches_sha256": _sha256(canonical_path),
        },
        "leagues": leagues,
        "history_policy": {
            "source": "opendota_canonical",
            "minimum_valid_maps": HISTORY_MIN_MAPS,
            "name_prefixes": ["Team "],
            "explicit_current_roster_names": sorted(HISTORY_TEAM_NAME_OVERRIDES),
            "market_matching_required_for_target": True,
        },
        "team_history": history_teams,
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
