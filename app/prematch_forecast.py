from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

from app.lolkills_inference import negative_binomial_pmf


FORECAST_TARGET = "pinnacle_last_prematch_implied_mean"
REQUIRED_NUMERIC_FEATURES = (
    "snapshot_mu",
    "lead_minutes",
    "snapshot_overround",
    "quote_count",
    "line_from_open",
    "mu_from_open",
    "recent_mu_change",
    "structural_disagreement",
    "structural_training_maps",
    "moneyline_training_maps",
    "blue_history_age_days",
    "red_history_age_days",
    "map_number",
    "theta",
)


def load_prematch_forecast_bundle(path: str | Path) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as handle:
        bundle = json.load(handle)
    required = {
        "model_id",
        "status",
        "target",
        "coefficients",
        "factor_levels",
        "residual_intervals",
        "minimum_conservative_ev",
    }
    missing = sorted(required - set(bundle))
    if missing:
        raise ValueError("Bundle de forecast incompleto: " + ", ".join(missing))
    return bundle


def _validate_features(features: dict[str, Any], bundle: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(features)
    missing = [name for name in REQUIRED_NUMERIC_FEATURES if normalized.get(name) is None]
    if missing:
        raise ValueError("Features de forecast ausentes: " + ", ".join(missing))
    for name in REQUIRED_NUMERIC_FEATURES:
        normalized[name] = float(normalized[name])
        if not math.isfinite(normalized[name]):
            raise ValueError(f"Feature de forecast inválida: {name}.")
    if normalized["theta"] <= 0 or normalized["snapshot_mu"] <= 0:
        raise ValueError("snapshot_mu e theta precisam ser positivos.")
    timing = str(normalized.get("timing_id") or "")
    if timing not in bundle["factor_levels"]["timing_id"]:
        raise ValueError("Timing não suportado pelo forecast.")
    normalized["timing_id"] = timing
    for factor in ("league_model", "blue_team_model", "red_team_model"):
        value = str(normalized.get(factor) or "")
        levels = bundle["factor_levels"][factor]
        normalized[factor] = value if value in levels else "OTHER"
    return normalized


def _coefficient_value(name: str, features: dict[str, Any]) -> float:
    if name == "(Intercept)":
        return 1.0
    if name in features and isinstance(features[name], (int, float)):
        return float(features[name])
    for factor in ("league_model", "blue_team_model", "red_team_model", "timing_id"):
        if name.startswith(factor):
            return float(str(features[factor]) == name[len(factor) :])
    return 0.0


def _probability_over(mean: float, theta: float, line: float) -> float:
    threshold = math.floor(float(line))
    pmf = negative_binomial_pmf(float(mean), float(theta))
    return 1 - sum(pmf[: threshold + 1])


def forecast_final_prematch(
    features: dict[str, Any],
    soft_line: float,
    soft_odds_over: float,
    soft_odds_under: float,
    bundle: dict[str, Any],
) -> dict[str, Any]:
    normalized = _validate_features(features, bundle)
    line = float(soft_line)
    odds_over = float(soft_odds_over)
    odds_under = float(soft_odds_under)
    if (
        line < 0.5
        or not math.isclose(line % 1, 0.5, abs_tol=1e-12)
        or odds_over <= 1
        or odds_under <= 1
    ):
        raise ValueError("Linha soft ou odds inválidas para o forecast.")
    predicted_delta = sum(
        float(coefficient) * _coefficient_value(name, normalized)
        for name, coefficient in bundle["coefficients"].items()
    )
    predicted_mean = normalized["snapshot_mu"] + predicted_delta
    interval = next(
        row
        for row in bundle["residual_intervals"]
        if row["timing_id"] == normalized["timing_id"]
    )
    mean_low = max(1e-6, predicted_mean + float(interval["lower"]))
    mean_high = max(mean_low, predicted_mean + float(interval["upper"]))
    theta = normalized["theta"]
    point_over = _probability_over(predicted_mean, theta, line)
    point_ev_over = point_over * odds_over - 1
    point_ev_under = (1 - point_over) * odds_under - 1
    conservative_over = _probability_over(mean_low, theta, line)
    conservative_under = 1 - _probability_over(mean_high, theta, line)
    conservative_ev_over = conservative_over * odds_over - 1
    conservative_ev_under = conservative_under * odds_under - 1
    recommended_side = (
        "over" if conservative_ev_over >= conservative_ev_under else "under"
    )
    best_ev = max(conservative_ev_over, conservative_ev_under)
    approved = bundle["status"] == "approved_for_micro_stake"
    eligible = approved and best_ev >= float(bundle["minimum_conservative_ev"])
    return {
        "model_id": bundle["model_id"],
        "model_status": bundle["status"],
        "version": bundle["model_id"],
        "forecast_target": FORECAST_TARGET,
        "soft_line": line,
        "predicted_delta_mu": predicted_delta,
        "predicted_last_mu": predicted_mean,
        "predicted_last_mu_low": mean_low,
        "predicted_last_mu_high": mean_high,
        "probability_over": point_over,
        "probability_under": 1 - point_over,
        "ev_over": point_ev_over,
        "ev_under": point_ev_under,
        "conservative_probability_over": conservative_over,
        "conservative_probability_under": conservative_under,
        "conservative_ev_over": conservative_ev_over,
        "conservative_ev_under": conservative_ev_under,
        "recommended_side": recommended_side if eligible else None,
        "action": "micro_bet" if eligible else "shadow_abstain",
        "stake": float(bundle.get("stake_units", 1)) if eligible else 0.0,
        "blocked_reasons": [] if eligible else [
            "Modelo A não passou todos os gates históricos."
            if not approved
            else "EV conservador abaixo do mínimo."
        ],
    }


def assess_soft_model_readiness(
    quotes: list[dict[str, Any]],
) -> dict[str, Any]:
    first_seen_rows = [row for row in quotes if row.get("quote_stage") == "first_seen"]

    def opportunity_key(row: dict[str, Any]) -> tuple[Any, ...]:
        if row.get("gameid"):
            return ("gameid", str(row["gameid"]))
        identity = (
            row.get("league"), row.get("planned_at"), row.get("blue_team"),
            row.get("red_team"), row.get("map_number"),
        )
        if (
            row.get("planned_at")
            and row.get("blue_team")
            and row.get("red_team")
            and row.get("map_number") is not None
        ):
            return ("identity", *identity)
        return ("quote_id", str(row.get("quote_id")))

    unique_opportunities = {opportunity_key(row) for row in first_seen_rows}
    leagues = {str(row.get("league")) for row in first_seen_rows if row.get("league")}
    first_seen = len(unique_opportunities)
    ready = first_seen >= 500 and len(leagues) >= 3
    return {
        "unique_quotes": first_seen,
        "first_seen_quotes": first_seen,
        "leagues": len(leagues),
        "development_rows": min(first_seen, 300),
        "confirmation_rows": max(0, min(first_seen - 300, 200)),
        "ready_to_train_model_b": ready,
        "status": "ready" if ready else "collecting",
    }
