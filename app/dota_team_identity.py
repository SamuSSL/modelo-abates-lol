from __future__ import annotations

from datetime import datetime, timezone
from typing import Any


FRESH_DAYS = 45
AGING_DAYS = 90


def _parse_utc(value: Any) -> datetime | None:
    if value in (None, ""):
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _canonical_name(value: Any) -> str:
    text = " ".join(str(value or "").strip().split())
    return text or "Identidade OpenDota desconhecida"


def _days_between(later: datetime, earlier: datetime) -> float:
    return max(0.0, (later - earlier).total_seconds() / 86400.0)


def build_operational_team_catalog(
    catalog: dict[str, Any], registry: dict[str, Any]
) -> list[dict[str, Any]]:
    registry_by_id = {
        str(row.get("opendota_team_id", row.get("team_id"))): dict(row)
        for row in registry.get("teams", registry.get("team_history", []))
        if row.get("opendota_team_id", row.get("team_id")) not in (None, "")
    }
    grouped: dict[str, dict[str, Any]] = {}
    raw_rows = list(catalog.get("team_history", []))
    for league in catalog.get("leagues", []):
        for raw_team in league.get("teams", []):
            raw_rows.append({
                **raw_team,
                "team_id": raw_team.get("team_id"),
                "team_name": raw_team.get("team_name"),
                "source_league_id": league.get("source_league_id"),
                "league_name": league.get("league_name"),
                "tier": league.get("tier"),
            })

    for raw in raw_rows:
        team_id = str(raw.get("team_id", raw.get("opendota_team_id", "")))
        if not team_id:
            continue
        name = _canonical_name(raw.get("team_name", team_id))
        key = name.casefold()
        group = grouped.setdefault(
            key,
            {
                "canonical_team_name": name,
                "historical_identities": [],
            },
        )
        identity = next(
            (
                row
                for row in group["historical_identities"]
                if row["opendota_team_id"] == team_id
            ),
            None,
        )
        observed = registry_by_id.get(team_id, {})
        if identity is None:
            identity = {
                "opendota_team_id": team_id,
                "team_name": name,
                "last_seen": raw.get("last_seen"),
                "map_count": int(raw.get("map_count", 0) or 0),
                "competitions": [],
                **{
                    key: observed[key]
                    for key in (
                        "last_observed_roster",
                        "last_observed_roster_members",
                        "last_roster_observed_at",
                        "roster_snapshot_count",
                        "previous_roster_overlap",
                        "roster_status",
                    )
                    if key in observed
                },
            }
            group["historical_identities"].append(identity)
        else:
            identity["map_count"] = max(
                int(identity.get("map_count", 0) or 0),
                int(raw.get("map_count", 0) or 0),
            )
            for key in (
                "last_observed_roster",
                "last_observed_roster_members",
                "last_roster_observed_at",
                "roster_snapshot_count",
                "previous_roster_overlap",
                "roster_status",
                "roster_source",
                "roster_evidence_retrieved_at",
                "current_membership_count",
            ):
                if key in observed:
                    identity[key] = observed[key]
            current_last_seen = _parse_utc(identity.get("last_seen"))
            candidate_last_seen = _parse_utc(raw.get("last_seen"))
            if candidate_last_seen and (
                current_last_seen is None or candidate_last_seen > current_last_seen
            ):
                identity["last_seen"] = raw.get("last_seen")
        league_id = raw.get("source_league_id")
        if league_id is not None:
            identity["competitions"].append({
                "source_league_id": str(league_id),
                "league_name": str(raw.get("league_name", league_id)),
                "tier": str(raw.get("tier", "")),
            })

    result = []
    for group in grouped.values():
        identities = group["historical_identities"]
        for identity in identities:
            unique_competitions = {
                row["source_league_id"]: row for row in identity["competitions"]
            }
            identity["competitions"] = sorted(
                unique_competitions.values(),
                key=lambda row: (row["league_name"].casefold(), row["source_league_id"]),
            )
        identities.sort(
            key=lambda row: (
                _parse_utc(row.get("last_seen")) or datetime.min.replace(tzinfo=timezone.utc),
                int(row.get("map_count", 0) or 0),
            ),
            reverse=True,
        )
        group["latest_identity"] = identities[0] if identities else None
        group["identity_count"] = len(identities)
        result.append(group)
    return sorted(result, key=lambda row: row["canonical_team_name"].casefold())


def classify_roster_transition(
    previous_roster: list[str], current_roster: list[str]
) -> dict[str, Any]:
    previous = {str(value) for value in previous_roster if value not in (None, "")}
    current = {str(value) for value in current_roster if value not in (None, "")}
    if len(previous) < 5 or len(current) < 5:
        return {
            "overlap_count": None,
            "changed_count": None,
            "roster_status": "unknown",
        }
    overlap = len(previous.intersection(current))
    changed = 5 - overlap
    if overlap == 5:
        status = "same_roster"
    elif overlap == 4:
        status = "minor_roster_change"
    elif overlap == 3:
        status = "partial_roster_change"
    else:
        status = "new_roster_version"
    return {
        "overlap_count": overlap,
        "changed_count": changed,
        "roster_status": status,
    }


def resolve_team_identity(
    candidates: list[dict[str, Any]],
    cutoff: str,
    approved_event_team_id: str | None = None,
) -> dict[str, Any]:
    cutoff_at = _parse_utc(cutoff)
    if cutoff_at is None:
        raise ValueError("cutoff must be a valid UTC timestamp")
    eligible = []
    for raw in candidates:
        observed_at = _parse_utc(raw.get("last_seen", raw.get("last_observed_at")))
        if observed_at is not None and observed_at <= cutoff_at:
            eligible.append({**raw, "opendota_team_id": str(raw["opendota_team_id"])})
    if not eligible:
        return {
            "opendota_team_id": None,
            "identity_status": "unknown",
            "resolution_method": "no_pre_cutoff_identity",
            "manual_comparison_blocked": True,
            "eligible_candidates": [],
        }

    chosen = None
    method = "latest_pre_cutoff_identity"
    if approved_event_team_id is not None:
        approved_id = str(approved_event_team_id)
        chosen = next(
            (row for row in eligible if row["opendota_team_id"] == approved_id),
            None,
        )
        if chosen is not None:
            method = "approved_event_identity"
    if chosen is None:
        eligible.sort(
            key=lambda row: (
                _parse_utc(row.get("last_seen", row.get("last_observed_at")))
                or datetime.min.replace(tzinfo=timezone.utc),
                int(row.get("map_count", 0) or 0),
            ),
            reverse=True,
        )
        chosen = eligible[0]

    observed_at = _parse_utc(chosen.get("last_seen", chosen.get("last_observed_at")))
    age_days = _days_between(cutoff_at, observed_at) if observed_at else None
    if age_days is None:
        identity_status = "unknown"
    elif age_days <= FRESH_DAYS:
        identity_status = "fresh"
    elif age_days <= AGING_DAYS:
        identity_status = "aging"
    else:
        identity_status = "stale"
    roster_status = str(chosen.get("roster_status", "unknown"))
    roster_evidence_at = _parse_utc(chosen.get("roster_evidence_retrieved_at"))
    roster_available_before_cutoff = (
        roster_evidence_at is not None and roster_evidence_at <= cutoff_at
    )
    if roster_status != "unknown" and not roster_available_before_cutoff:
        roster_status = "unknown"
    ambiguous = len(eligible) > 1 and method != "approved_event_identity" and all(
        _parse_utc(row.get("last_seen", row.get("last_observed_at"))) is not None
        for row in eligible
    ) and abs(
        (
            _parse_utc(eligible[0].get("last_seen", eligible[0].get("last_observed_at")))
            - _parse_utc(eligible[1].get("last_seen", eligible[1].get("last_observed_at")))
        ).total_seconds()
    ) <= 45 * 86400
    if ambiguous:
        identity_status = "ambiguous"
    return {
        "opendota_team_id": chosen["opendota_team_id"],
        "last_seen": chosen.get("last_seen", chosen.get("last_observed_at")),
        "age_days": age_days,
        "identity_status": identity_status,
        "roster_status": roster_status,
        "roster_available_before_cutoff": roster_available_before_cutoff,
        "roster_evidence_retrieved_at": chosen.get("roster_evidence_retrieved_at"),
        "resolution_method": method,
        "manual_comparison_blocked": False,
        "eligible_candidates": [row["opendota_team_id"] for row in eligible],
        "selected_identity": chosen,
    }
