from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

from app.lolkills_inference import negative_binomial_pmf


def load_synthetic_pinnacle_bundle(path: str | Path) -> dict[str, Any]:
    with Path(path).open(encoding="utf-8") as handle:
        bundle = json.load(handle)
    if bundle.get("target_mode") == "direct_line_price":
        required = {
            "model_id", "status", "feature_names", "feature_medians",
            "league_levels", "line_model", "price_model", "hold_model",
            "market_probability_logit_slope_per_kill",
            "minimum_conservative_ev",
        }
    else:
        required = {
            "model_id", "status", "feature_names", "feature_medians",
            "league_levels", "coefficients", "market_theta",
            "interval_residual", "minimum_conservative_ev",
        }
    missing = sorted(required - set(bundle))
    if missing:
        raise ValueError("Bundle da Pinnacle sintética incompleto: " + ", ".join(missing))
    return bundle


def _mean(first: float, second: float) -> float:
    return 0.5 * (float(first) + float(second))


def build_team_pair_features(
    team_a: dict[str, Any],
    team_b: dict[str, Any],
    map_number: int,
) -> dict[str, float]:
    ratings_a = team_a.get("ratings") or {}
    ratings_b = team_b.get("ratings") or {}
    features: dict[str, float] = {
        "map_number": float(min(int(map_number), 5)),
        "pace": _mean(team_a["hist_pace"], team_b["hist_pace"]),
    }
    for window in ("season", "last15"):
        def value(ratings: dict[str, Any], metric: str) -> float:
            return float(ratings[f"{window}_{metric}"])

        attack_a = value(ratings_a, "attack_ratio")
        attack_b = value(ratings_b, "attack_ratio")
        concession_a = value(ratings_a, "concession_ratio")
        concession_b = value(ratings_b, "concession_ratio")
        kpm_a = value(ratings_a, "kpm_ratio")
        kpm_b = value(ratings_b, "kpm_ratio")
        dpm_a = value(ratings_a, "dpm_ratio")
        dpm_b = value(ratings_b, "dpm_ratio")
        prefix = f"{window}_"
        features[f"{prefix}team_games_min"] = min(
            value(ratings_a, "team_games"),
            value(ratings_b, "team_games"),
        )
        features[f"{prefix}attack_mean"] = _mean(attack_a, attack_b)
        features[f"{prefix}concession_mean"] = _mean(concession_a, concession_b)
        features[f"{prefix}matchup_count"] = 0.5 * (
            attack_a * concession_b + attack_b * concession_a
        )
        features[f"{prefix}matchup_rate"] = 0.5 * (
            kpm_a * dpm_b + kpm_b * dpm_a
        )
        features[f"{prefix}kpm_mean"] = _mean(kpm_a, kpm_b)
        features[f"{prefix}dpm_mean"] = _mean(dpm_a, dpm_b)
        features[f"{prefix}duration_mean"] = _mean(
            value(ratings_a, "duration_ratio"),
            value(ratings_b, "duration_ratio"),
        )
        features[f"{prefix}volatility_mean"] = _mean(
            value(ratings_a, "total_kills_sd_ratio"),
            value(ratings_b, "total_kills_sd_ratio"),
        )
        features[f"{prefix}attack_gap"] = abs(attack_a - attack_b)
        features[f"{prefix}concession_gap"] = abs(concession_a - concession_b)
        features[f"{prefix}rate_gap"] = abs(
            (kpm_a + dpm_a) - (kpm_b + dpm_b)
        )
        league_kills = _mean(
            value(ratings_a, "league_kills_per_map"),
            value(ratings_b, "league_kills_per_map"),
        )
        league_deaths = _mean(
            value(ratings_a, "league_deaths_per_map"),
            value(ratings_b, "league_deaths_per_map"),
        )
        features[f"{prefix}league_total"] = league_kills + league_deaths
        features[f"{prefix}league_duration"] = _mean(
            value(ratings_a, "league_duration"),
            value(ratings_b, "league_duration"),
        )
        features[f"{prefix}structural_proxy"] = (
            features[f"{prefix}league_total"]
            * features[f"{prefix}matchup_count"]
        )
    features["minimum_history"] = min(
        features["season_team_games_min"],
        features["last15_team_games_min"],
    )
    return features


def _probability_over(mean: float, theta: float, line: float) -> float:
    pmf = negative_binomial_pmf(mean, theta)
    return 1 - sum(pmf[: math.floor(line) + 1])


def _logistic(value: float) -> float:
    if value >= 0:
        exponential = math.exp(-value)
        return 1 / (1 + exponential)
    exponential = math.exp(value)
    return exponential / (1 + exponential)


def _linear_prediction(
    normalized: dict[str, float],
    league_model: str,
    model: dict[str, Any],
) -> float:
    coefficients = model["coefficients"]
    prediction = float(coefficients["(Intercept)"])
    for name, value in normalized.items():
        prediction += float(coefficients.get(name, 0.0)) * value
    prediction += float(coefficients.get(f"league_model{league_model}", 0.0))
    return prediction


def _direct_quote_metrics(
    predicted_line_raw: float,
    predicted_price_logit: float,
    line: float,
    odds_over: float,
    odds_under: float,
    bundle: dict[str, Any],
) -> dict[str, Any]:
    slope = float(bundle["market_probability_logit_slope_per_kill"])
    line_interval = bundle["line_model"]["residual_interval"]
    price_interval = bundle["price_model"]["residual_logit_interval"]
    central_logit = predicted_price_logit + slope * (predicted_line_raw - line)
    probability_over = _logistic(central_logit)
    probability_under = 1 - probability_over
    conservative_over_logit = (
        predicted_price_logit
        + float(price_interval["lower"])
        + slope * (
            predicted_line_raw + float(line_interval["lower"]) - line
        )
    )
    conservative_under_logit = (
        predicted_price_logit
        + float(price_interval["upper"])
        + slope * (
            predicted_line_raw + float(line_interval["upper"]) - line
        )
    )
    conservative_over = _logistic(conservative_over_logit)
    conservative_under = 1 - _logistic(conservative_under_logit)
    raw_soft_over = 1 / odds_over
    raw_soft_under = 1 / odds_under
    soft_probability_over = raw_soft_over / (raw_soft_over + raw_soft_under)
    ev_over = probability_over * odds_over - 1
    ev_under = probability_under * odds_under - 1
    conservative_ev_over = conservative_over * odds_over - 1
    conservative_ev_under = conservative_under * odds_under - 1
    best_side = "over" if conservative_ev_over >= conservative_ev_under else "under"
    best_conservative_ev = max(conservative_ev_over, conservative_ev_under)
    best_point_ev = max(ev_over, ev_under)
    if best_conservative_ev >= float(bundle["minimum_conservative_ev"]):
        confidence = "alta"
    elif best_conservative_ev > 0 or best_point_ev >= float(bundle["minimum_conservative_ev"]):
        confidence = "média"
    else:
        confidence = "baixa"
    return {
        "soft_line": line,
        "soft_odds_over": odds_over,
        "soft_odds_under": odds_under,
        "soft_no_vig_probability_over": soft_probability_over,
        "probability_over": probability_over,
        "probability_under": probability_under,
        "fair_odds_over": 1 / probability_over,
        "fair_odds_under": 1 / probability_under,
        "ev_over": ev_over,
        "ev_under": ev_under,
        "conservative_probability_over": conservative_over,
        "conservative_probability_under": conservative_under,
        "conservative_ev_over": conservative_ev_over,
        "conservative_ev_under": conservative_ev_under,
        "recommended_side": best_side if best_conservative_ev >= float(
            bundle["minimum_conservative_ev"]
        ) else None,
        "confidence": confidence,
        "confidence_edge_probability": probability_over - soft_probability_over,
    }


def _predict_direct_market_from_features(
    normalized: dict[str, float],
    league_model: str,
    line: float,
    odds_over: float,
    odds_under: float,
    bundle: dict[str, Any],
) -> dict[str, Any]:
    predicted_line_raw = _linear_prediction(
        normalized, league_model, bundle["line_model"]
    )
    predicted_line = round(predicted_line_raw * 2) / 2
    predicted_price_logit = _linear_prediction(
        normalized, league_model, bundle["price_model"]
    )
    predicted_probability_over = _logistic(predicted_price_logit)
    predicted_hold = math.exp(_linear_prediction(
        normalized, league_model, bundle["hold_model"]
    ))
    predicted_odds_over = 1 / (predicted_probability_over * predicted_hold)
    predicted_odds_under = 1 / (
        (1 - predicted_probability_over) * predicted_hold
    )
    quote = _direct_quote_metrics(
        predicted_line_raw, predicted_price_logit, line,
        odds_over, odds_under, bundle,
    )
    enough_history = normalized["minimum_history"] >= float(
        bundle.get("minimum_history_required", 5)
    )
    signal = (
        bundle["status"] == "approved_for_manual_soft_comparison"
        and enough_history
        and quote["recommended_side"] is not None
    )
    line_interval = bundle["line_model"]["residual_interval"]
    quote.update({
        "model_id": bundle["model_id"],
        "model_status": bundle["status"],
        "forecast_target": bundle["target"],
        "predicted_final_line": predicted_line,
        "predicted_final_line_raw": predicted_line_raw,
        "predicted_final_line_low": (
            predicted_line_raw + float(line_interval["lower"])
        ),
        "predicted_final_line_high": (
            predicted_line_raw + float(line_interval["upper"])
        ),
        "predicted_final_probability_over": predicted_probability_over,
        "predicted_final_probability_under": 1 - predicted_probability_over,
        "predicted_final_odds_over": predicted_odds_over,
        "predicted_final_odds_under": predicted_odds_under,
        "predicted_final_hold": predicted_hold,
        "recommended_side": quote["recommended_side"] if signal else None,
        "action": "manual_review" if signal else "abstain",
        "stake": 0.0,
        "automatic_betting_approved": False,
        "minimum_history": normalized["minimum_history"],
        "features": normalized,
        "blocked_reasons": [] if signal else [
            "EV conservador abaixo do mínimo, amostra insuficiente ou modelo em shadow."
        ],
    })
    return quote


def predict_synthetic_pinnacle_from_features(
    features: dict[str, Any],
    league: str,
    soft_line: float,
    soft_odds_over: float,
    soft_odds_under: float,
    bundle: dict[str, Any],
) -> dict[str, Any]:
    line = float(soft_line)
    odds_over = float(soft_odds_over)
    odds_under = float(soft_odds_under)
    if not math.isclose(line % 1, 0.5, abs_tol=1e-12) or odds_over <= 1 or odds_under <= 1:
        raise ValueError("Linha ou odds soft inválidas.")
    normalized: dict[str, float] = {}
    for name in bundle["feature_names"]:
        value = features.get(name, bundle["feature_medians"][name])
        value = float(value)
        if not math.isfinite(value):
            value = float(bundle["feature_medians"][name])
        normalized[name] = value
    league_model = league if league in bundle["league_levels"] else "OTHER"
    if bundle.get("target_mode") == "direct_line_price":
        return _predict_direct_market_from_features(
            normalized, league_model, line, odds_over, odds_under, bundle
        )
    prediction = float(bundle["coefficients"]["(Intercept)"])
    for name, value in normalized.items():
        prediction += float(bundle["coefficients"].get(name, 0.0)) * value
    league_coefficient = f"league_model{league_model}"
    prediction += float(bundle["coefficients"].get(league_coefficient, 0.0))
    prediction = max(1e-6, prediction)
    interval = bundle["interval_residual"]
    mean_low = max(1e-6, prediction + float(interval["lower"]))
    mean_high = max(mean_low, prediction + float(interval["upper"]))
    theta = float(bundle["market_theta"])
    probability_over = _probability_over(prediction, theta, line)
    probability_under = 1 - probability_over
    conservative_over = _probability_over(mean_low, theta, line)
    conservative_under = 1 - _probability_over(mean_high, theta, line)
    ev_over = probability_over * odds_over - 1
    ev_under = probability_under * odds_under - 1
    conservative_ev_over = conservative_over * odds_over - 1
    conservative_ev_under = conservative_under * odds_under - 1
    side = "over" if conservative_ev_over >= conservative_ev_under else "under"
    best_ev = max(conservative_ev_over, conservative_ev_under)
    enough_history = normalized["minimum_history"] >= float(
        bundle.get("minimum_history_required", 5)
    )
    signal = (
        bundle["status"] == "approved_for_manual_soft_comparison"
        and enough_history
        and best_ev >= float(bundle["minimum_conservative_ev"])
    )
    return {
        "model_id": bundle["model_id"],
        "model_status": bundle["status"],
        "forecast_target": bundle["target"],
        "predicted_last_mu": prediction,
        "predicted_last_mu_low": mean_low,
        "predicted_last_mu_high": mean_high,
        "probability_over": probability_over,
        "probability_under": probability_under,
        "fair_odds_over": 1 / probability_over,
        "fair_odds_under": 1 / probability_under,
        "ev_over": ev_over,
        "ev_under": ev_under,
        "conservative_probability_over": conservative_over,
        "conservative_probability_under": conservative_under,
        "conservative_ev_over": conservative_ev_over,
        "conservative_ev_under": conservative_ev_under,
        "recommended_side": side if signal else None,
        "action": "manual_review" if signal else "abstain",
        "stake": 0.0,
        "automatic_betting_approved": False,
        "minimum_history": normalized["minimum_history"],
        "features": normalized,
        "blocked_reasons": [] if signal else [
            "EV conservador abaixo do mínimo ou amostra insuficiente."
        ],
    }


def predict_synthetic_pinnacle(
    team_a: dict[str, Any],
    team_b: dict[str, Any],
    league: str,
    map_number: int,
    soft_line: float,
    soft_odds_over: float,
    soft_odds_under: float,
    bundle: dict[str, Any],
) -> dict[str, Any]:
    features = build_team_pair_features(team_a, team_b, map_number)
    if bundle.get("target_mode") == "direct_line_price":
        roster_by_team = bundle.get("team_roster_features") or {}
        first_roster = roster_by_team.get(str(team_a.get("team_id"))) or {}
        second_roster = roster_by_team.get(str(team_b.get("team_id"))) or {}
        roster_metrics = (
            "player_games_min", "player_games_mean", "roster_kpm",
            "roster_deaths_pm", "roster_conflict_pm", "roster_damage_pm",
            "roster_kill_participation", "roster_continuity",
            "roster_change", "roster_days_together", "roster_size",
        )
        for metric in roster_metrics:
            first = float(first_roster.get(metric, math.nan))
            second = float(second_roster.get(metric, math.nan))
            if math.isfinite(first) and math.isfinite(second):
                features[f"{metric}_mean"] = _mean(first, second)
                features[f"{metric}_gap"] = abs(first - second)
    return predict_synthetic_pinnacle_from_features(
        features,
        league,
        soft_line,
        soft_odds_over,
        soft_odds_under,
        bundle,
    )


def predict_synthetic_pinnacle_quotes(
    team_a: dict[str, Any],
    team_b: dict[str, Any],
    league: str,
    map_number: int,
    soft_quotes: list[dict[str, float]],
    bundle: dict[str, Any],
) -> list[dict[str, Any]]:
    if len(soft_quotes) != 3:
        raise ValueError("Informe exatamente três cotações soft.")
    return [
        predict_synthetic_pinnacle(
            team_a, team_b, league, map_number,
            float(quote["line"]), float(quote["odds_over"]),
            float(quote["odds_under"]), bundle,
        )
        for quote in soft_quotes
    ]
