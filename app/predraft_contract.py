from __future__ import annotations

import hashlib
import math
from datetime import datetime, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo


EV_THRESHOLDS = (0.0, 0.03, 0.05, 0.08, 0.10)
ROSTER_UNLOCK_MAPS = 5
SNAPSHOT_MIN_LEAD_MINUTES = 30
SNAPSHOT_MAX_LEAD_MINUTES = 45


class PredraftContractError(ValueError):
    pass


def no_vig_probabilities(
    first_odds: float,
    second_odds: float,
) -> tuple[float, float]:
    first = float(first_odds)
    second = float(second_odds)
    if (
        not math.isfinite(first)
        or not math.isfinite(second)
        or first <= 1
        or second <= 1
    ):
        raise PredraftContractError(
            "As duas odds precisam ser decimais e maiores que 1."
        )
    raw_first = 1 / first
    raw_second = 1 / second
    total = raw_first + raw_second
    return raw_first / total, raw_second / total


def validate_half_line(value: Any, label: str) -> float:
    line = float(value)
    if not math.isfinite(line) or line < 0.5 or not math.isclose(
        line % 1,
        0.5,
        abs_tol=1e-12,
    ):
        raise PredraftContractError(f"{label} precisa terminar em .5.")
    return line


def normalize_predraft_request(
    request: dict[str, Any],
) -> dict[str, Any]:
    required = (
        "league",
        "planned_at",
        "map_number",
        "team_a",
        "team_b",
        "soft_line",
        "soft_odds_over",
        "soft_odds_under",
        "moneyline_team_a_odds",
        "moneyline_team_b_odds",
    )
    missing = [name for name in required if request.get(name) is None]
    if missing:
        raise PredraftContractError(
            "Campos obrigatorios ausentes: " + ", ".join(missing) + "."
        )
    planned_at = datetime.fromisoformat(
        str(request["planned_at"]).replace("Z", "+00:00")
    )
    if planned_at.tzinfo is None:
        raise PredraftContractError("planned_at precisa informar o fuso.")
    validate_half_line(request["soft_line"], "A linha soft")
    no_vig_probabilities(
        request["soft_odds_over"],
        request["soft_odds_under"],
    )
    no_vig_probabilities(
        request["moneyline_team_a_odds"],
        request["moneyline_team_b_odds"],
    )
    if request["team_a"].get("team_name") == request["team_b"].get(
        "team_name"
    ):
        raise PredraftContractError("As equipes A e B devem ser diferentes.")
    for label in ("team_a", "team_b"):
        starters = request[label].get("starters") or []
        identities = [str(row.get("player_id") or "") for row in starters]
        if len(starters) != 5 or any(not value for value in identities):
            raise PredraftContractError(
                "Cada equipe precisa de cinco titulares identificados."
            )
        if len(set(identities)) != 5:
            raise PredraftContractError(
                "Os cinco titulares de uma equipe precisam ser unicos."
            )
    normalized = dict(request)
    normalized["soft_line"] = float(request["soft_line"])
    normalized["soft_odds_over"] = float(request["soft_odds_over"])
    normalized["soft_odds_under"] = float(request["soft_odds_under"])
    normalized["moneyline_team_a_odds"] = float(
        request["moneyline_team_a_odds"]
    )
    normalized["moneyline_team_b_odds"] = float(
        request["moneyline_team_b_odds"]
    )
    for prefix in ("pinnacle_total", "team_a_total", "team_b_total"):
        line_name = f"{prefix}_line"
        over_name = f"{prefix}_odds_over"
        under_name = f"{prefix}_odds_under"
        supplied = [normalized.get(line_name), normalized.get(over_name), normalized.get(under_name)]
        if any(value is not None for value in supplied):
            if not all(value is not None for value in supplied):
                raise PredraftContractError(
                    f"{prefix} exige linha e as duas odds."
                )
            normalized[line_name] = validate_half_line(
                normalized[line_name],
                prefix,
            )
            no_vig_probabilities(
                normalized[over_name],
                normalized[under_name],
            )
            normalized[over_name] = float(normalized[over_name])
            normalized[under_name] = float(normalized[under_name])
    return normalized


def legacy_request_from_predraft(
    request: dict[str, Any],
    swap: bool = False,
) -> dict[str, Any]:
    normalized = normalize_predraft_request(request)
    first = "team_b" if swap else "team_a"
    second = "team_a" if swap else "team_b"
    first_odds = (
        normalized["moneyline_team_b_odds"]
        if swap
        else normalized["moneyline_team_a_odds"]
    )
    second_odds = (
        normalized["moneyline_team_a_odds"]
        if swap
        else normalized["moneyline_team_b_odds"]
    )
    return {
        "league": normalized["league"],
        "planned_at": normalized["planned_at"],
        "map_number": int(normalized["map_number"]),
        "line": float(normalized["soft_line"]),
        "odds_over": float(normalized["soft_odds_over"]),
        "odds_under": float(normalized["soft_odds_under"]),
        "moneyline_blue_odds": first_odds,
        "moneyline_red_odds": second_odds,
        "blue": {
            "team_name": normalized[first]["team_name"],
            "team_id": normalized[first].get("team_id"),
        },
        "red": {
            "team_name": normalized[second]["team_name"],
            "team_id": normalized[second].get("team_id"),
        },
    }


def roster_signature(starters: list[dict[str, Any]]) -> str:
    identities = sorted(str(row["player_id"]) for row in starters)
    return hashlib.sha256("|".join(identities).encode("utf-8")).hexdigest()[:20]


def evaluate_roster_gate(
    request: dict[str, Any],
    roster_catalog: dict[str, Any] | None,
) -> dict[str, Any]:
    if not roster_catalog:
        return {
            "blocked": True,
            "reasons": ["Catalogo de titulares indisponivel. Nao apostar."],
            "teams": {},
        }
    team_catalog = roster_catalog.get("teams") or {}
    signatures = roster_catalog.get("roster_signatures") or {}
    reasons: list[str] = []
    audit: dict[str, Any] = {}
    for label in ("team_a", "team_b"):
        team = request[label]
        team_key = str(team.get("team_id") or team.get("team_name"))
        reference = team_catalog.get(team_key) or {}
        selected_ids = {
            str(row["player_id"]) for row in team.get("starters") or []
        }
        reference_ids = {
            str(value) for value in reference.get("latest_roster", [])
        }
        changes = len(selected_ids - reference_ids) if reference_ids else 5
        signature = roster_signature(team["starters"])
        known_maps = int((signatures.get(signature) or {}).get("maps", 0))
        material_change = changes >= 2
        blocked = material_change and known_maps < ROSTER_UNLOCK_MAPS
        if blocked:
            reasons.append(
                f"{team['team_name']}: {changes} titulares trocados e "
                f"{known_maps}/{ROSTER_UNLOCK_MAPS} mapas do novo roster."
            )
        audit[label] = {
            "team_key": team_key,
            "reference_roster": sorted(reference_ids),
            "selected_roster": sorted(selected_ids),
            "roster_signature": signature,
            "starter_changes": changes,
            "known_roster_maps": known_maps,
            "material_change": material_change,
            "blocked": blocked,
        }
    return {"blocked": bool(reasons), "reasons": reasons, "teams": audit}


def prediction_lead_minutes(request: dict[str, Any]) -> float:
    planned = datetime.fromisoformat(
        str(request["planned_at"]).replace("Z", "+00:00")
    ).astimezone(timezone.utc)
    quoted = request.get("quoted_at")
    if quoted is None:
        quoted_at = datetime.now(timezone.utc)
    else:
        quoted_at = datetime.fromisoformat(
            str(quoted).replace("Z", "+00:00")
        ).astimezone(timezone.utc)
    return (planned - quoted_at).total_seconds() / 60


def evaluate_operational_gate(
    request: dict[str, Any],
    bundle_metadata: dict[str, Any],
) -> dict[str, Any]:
    """Block actionable bets when the prospective protocol is not respected."""
    lead_minutes = prediction_lead_minutes(request)
    reasons: list[str] = []
    if not (
        SNAPSHOT_MIN_LEAD_MINUTES
        <= lead_minutes
        <= SNAPSHOT_MAX_LEAD_MINUTES
    ):
        reasons.append(
            "Cotacao registrada fora da janela operacional T-45/T-30."
        )

    refreshed_at_raw = bundle_metadata.get("bundle_refreshed_at")
    refreshed_at = None
    valid_through = None
    if refreshed_at_raw:
        operation_timezone = ZoneInfo("America/Sao_Paulo")
        refreshed_at = datetime.fromisoformat(
            str(refreshed_at_raw).replace("Z", "+00:00")
        ).astimezone(operation_timezone)
        quoted_raw = request.get("quoted_at")
        quoted_at = (
            datetime.fromisoformat(str(quoted_raw).replace("Z", "+00:00"))
            if quoted_raw
            else datetime.now(timezone.utc)
        ).astimezone(operation_timezone)
        days_until_saturday = (5 - refreshed_at.weekday()) % 7
        if days_until_saturday == 0:
            days_until_saturday = 7
        valid_through = (
            refreshed_at.replace(
                hour=23,
                minute=59,
                second=59,
                microsecond=999999,
            )
            + timedelta(days=days_until_saturday)
        )
        if quoted_at > valid_through:
            reasons.append(
                "Bundle semanal vencido. Atualize o modelo antes de apostar."
            )
    else:
        reasons.append(
            "Data de atualizacao do bundle ausente. Nao apostar."
        )

    return {
        "blocked": bool(reasons),
        "reasons": reasons,
        "prediction_anchor": "scheduled_map_start",
        "snapshot_window_minutes": [
            SNAPSHOT_MIN_LEAD_MINUTES,
            SNAPSHOT_MAX_LEAD_MINUTES,
        ],
        "prediction_lead_minutes": lead_minutes,
        "bundle_refreshed_at": (
            refreshed_at.isoformat() if refreshed_at is not None else None
        ),
        "bundle_valid_through": (
            valid_through.isoformat() if valid_through is not None else None
        ),
    }
