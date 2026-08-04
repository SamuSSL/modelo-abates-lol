from __future__ import annotations

import math
from typing import Any

from app.lolkills_inference import negative_binomial_pmf
from app.predraft_contract import EV_THRESHOLDS, no_vig_probabilities


def _probability_over(pmf: list[float], line: float) -> float:
    threshold = math.floor(float(line))
    return 1 - sum(pmf[: threshold + 1])


def _nb_probability_over(mean: float, theta: float, line: float) -> float:
    return _probability_over(negative_binomial_pmf(mean, theta), line)


def invert_negative_binomial_mean(
    line: float,
    probability_over: float,
    theta: float,
) -> float:
    if not 0 < probability_over < 1 or theta <= 0:
        raise ValueError("Probabilidade ou theta invalidos.")
    lower = 1e-8
    upper = max(1.0, float(line) + 1)
    while _nb_probability_over(upper, theta, line) < probability_over:
        upper *= 2
        if upper > 1e6:
            raise RuntimeError("Nao foi possivel inverter o mercado.")
    for _ in range(100):
        middle = (lower + upper) / 2
        if _nb_probability_over(middle, theta, line) < probability_over:
            lower = middle
        else:
            upper = middle
    return (lower + upper) / 2


def _poisson_probability_over(mean: float, line: float) -> float:
    threshold = math.floor(float(line))
    mass = math.exp(-mean)
    cumulative = mass
    for value in range(1, threshold + 1):
        mass *= mean / value
        cumulative += mass
    return 1 - cumulative


def invert_poisson_mean(line: float, probability_over: float) -> float:
    lower = 1e-8
    upper = max(1.0, float(line) + 1)
    while _poisson_probability_over(upper, line) < probability_over:
        upper *= 2
        if upper > 1e6:
            raise RuntimeError("Nao foi possivel inverter o mercado.")
    for _ in range(100):
        middle = (lower + upper) / 2
        if _poisson_probability_over(middle, line) < probability_over:
            lower = middle
        else:
            upper = middle
    return (lower + upper) / 2


def _paper_rules(
    probability_over: float,
    soft_odds_over: float,
    soft_odds_under: float,
) -> list[dict[str, Any]]:
    probability_under = 1 - probability_over
    ev_over = probability_over * soft_odds_over - 1
    ev_under = probability_under * soft_odds_under - 1
    if ev_over >= ev_under:
        side, probability, odds, expected_value = (
            "over",
            probability_over,
            soft_odds_over,
            ev_over,
        )
    else:
        side, probability, odds, expected_value = (
            "under",
            probability_under,
            soft_odds_under,
            ev_under,
        )
    return [
        {
            "minimum_ev": threshold,
            "decision": "bet" if expected_value > threshold else "pass",
            "side": side if expected_value > threshold else None,
            "probability": probability if expected_value > threshold else None,
            "odds": odds if expected_value > threshold else None,
            "expected_value": expected_value,
            "stake": 1.0 if expected_value > threshold else 0.0,
        }
        for threshold in EV_THRESHOLDS
    ]


def _shadow_row(
    model_id: str,
    mode: str,
    pmf: list[float],
    request: dict[str, Any],
    diagnostics: dict[str, Any] | None = None,
) -> dict[str, Any]:
    soft_line = float(request["soft_line"])
    probability_over = _probability_over(pmf, soft_line)
    row = {
        "model_id": model_id,
        "mode": mode,
        "pmf": pmf,
        "mean": sum(index * mass for index, mass in enumerate(pmf)),
        "probability_over_soft": probability_over,
        "probability_under_soft": 1 - probability_over,
        "paper_rules": _paper_rules(
            probability_over,
            float(request["soft_odds_over"]),
            float(request["soft_odds_under"]),
        ),
        "diagnostics": diagnostics or {},
    }
    pinnacle_line = request.get("pinnacle_total_line")
    if pinnacle_line is not None:
        pinnacle_over = _probability_over(pmf, float(pinnacle_line))
        row["probability_over_pinnacle"] = pinnacle_over
        row["probability_under_pinnacle"] = 1 - pinnacle_over
    return row


def build_shadow_predictions(
    request: dict[str, Any],
    visible_result: dict[str, Any],
    bundle: dict[str, Any],
) -> list[dict[str, Any]]:
    if visible_result.get("status") != "ok":
        return []
    rows = [
        _shadow_row(
            "weekly_directed_raw",
            "fundamental",
            list(visible_result["pmf"]),
            request,
        )
    ]
    line = request.get("pinnacle_total_line")
    over_odds = request.get("pinnacle_total_odds_over")
    under_odds = request.get("pinnacle_total_odds_under")
    if line is None or over_odds is None or under_odds is None:
        rows.append(
            _shadow_row(
                "market_implied_count",
                "fundamental_fallback",
                list(visible_result["pmf"]),
                request,
                {"fallback_reason": "pinnacle_total_missing"},
            )
        )
        return rows
    probability_over, probability_under = no_vig_probabilities(
        over_odds,
        under_odds,
    )
    theta = float(bundle["model"]["theta"])
    exact_mean = invert_negative_binomial_mean(
        float(line),
        probability_over,
        theta,
    )
    poisson_mean = invert_poisson_mean(float(line), probability_over)
    diagnostics = {
        "pinnacle_probability_over": probability_over,
        "pinnacle_probability_under": probability_under,
        "pinnacle_line": float(line),
        "theta": theta,
    }
    rows.extend(
        [
            _shadow_row(
                "market_implied_nb_exact",
                "market_available",
                negative_binomial_pmf(exact_mean, theta),
                request,
                {**diagnostics, "implied_mean": exact_mean},
            ),
            _shadow_row(
                "market_poisson_center_nb",
                "market_available",
                negative_binomial_pmf(poisson_mean, theta),
                request,
                {**diagnostics, "implied_mean": poisson_mean},
            ),
            _shadow_row(
                "market_directed_blend_w070",
                "prospective_diagnostic",
                negative_binomial_pmf(
                    math.exp(
                        0.7 * math.log(float(visible_result["mean"]))
                        + 0.3 * math.log(exact_mean)
                    ),
                    theta,
                ),
                request,
                {
                    **diagnostics,
                    "market_implied_mean": exact_mean,
                    "directed_mean": float(visible_result["mean"]),
                    "fundamental_weight": 0.7,
                    "selection_status": "prospective_only_not_promoted",
                },
            ),
        ]
    )
    team_means: dict[str, float] = {}
    for team_label in ("team_a", "team_b"):
        team_line = request.get(f"{team_label}_total_line")
        team_over = request.get(f"{team_label}_total_odds_over")
        team_under = request.get(f"{team_label}_total_odds_under")
        if team_line is None or team_over is None or team_under is None:
            continue
        team_probability, _ = no_vig_probabilities(team_over, team_under)
        team_means[team_label] = invert_poisson_mean(
            float(team_line),
            team_probability,
        )
    if len(team_means) == 2:
        sum_team_means = team_means["team_a"] + team_means["team_b"]
        share_a = team_means["team_a"] / sum_team_means
        for row in rows:
            if row["mode"] == "market_available":
                row["diagnostics"].update(
                    {
                        "team_a_implied_share": share_a,
                        "team_b_implied_share": 1 - share_a,
                        "team_total_sum_gap": sum_team_means
                        - row["diagnostics"]["implied_mean"],
                    }
                )
    return rows
