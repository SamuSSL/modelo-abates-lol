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


def _pmf_quantile(pmf: list[float], probability: float) -> int:
    cumulative = 0.0
    for value, mass in enumerate(pmf):
        cumulative += float(mass)
        if cumulative >= probability:
            return value
    return len(pmf) - 1


def _preferred_ev_side(ev_over: float, ev_under: float) -> str:
    return "over" if ev_over >= ev_under else "under"


def evaluate_model_agreement(
    request: dict[str, Any],
    structural_result: dict[str, Any],
    pinnacle_reference: dict[str, Any] | None,
) -> dict[str, Any]:
    structural_ev_over = float(structural_result["probability_over"]) * float(
        request["soft_odds_over"]
    ) - 1
    structural_ev_under = float(structural_result["probability_under"]) * float(
        request["soft_odds_under"]
    ) - 1
    structural_side = _preferred_ev_side(
        structural_ev_over,
        structural_ev_under,
    )
    if pinnacle_reference is None:
        return {
            "status": "unavailable",
            "models_agree": None,
            "message": "Confiômetro indisponível sem Pinnacle pós-draft.",
            "structural_preferred_side": structural_side,
            "pinnacle_preferred_side": None,
            "structural_ev_over": structural_ev_over,
            "structural_ev_under": structural_ev_under,
            "pinnacle_ev_over": None,
            "pinnacle_ev_under": None,
        }
    pinnacle_ev_over = float(
        pinnacle_reference["probability_over_soft"]
    ) * float(request["soft_odds_over"]) - 1
    pinnacle_ev_under = float(
        pinnacle_reference["probability_under_soft"]
    ) * float(request["soft_odds_under"]) - 1
    pinnacle_side = _preferred_ev_side(pinnacle_ev_over, pinnacle_ev_under)
    models_agree = structural_side == pinnacle_side
    return {
        "status": "agree" if models_agree else "disagree",
        "models_agree": models_agree,
        "message": (
            "Modelos concordam entre si"
            if models_agree
            else "Modelos não concordam"
        ),
        "structural_preferred_side": structural_side,
        "pinnacle_preferred_side": pinnacle_side,
        "structural_ev_over": structural_ev_over,
        "structural_ev_under": structural_ev_under,
        "pinnacle_ev_over": pinnacle_ev_over,
        "pinnacle_ev_under": pinnacle_ev_under,
    }


def build_operational_prediction(
    request: dict[str, Any],
    structural_result: dict[str, Any],
    shadow_rows: list[dict[str, Any]],
) -> dict[str, Any]:
    pinnacle_reference = next(
        (
            row
            for row in shadow_rows
            if row.get("model_id") == "market_implied_nb_exact"
        ),
        None,
    )
    if pinnacle_reference is None:
        pmf = list(structural_result["pmf"])
        probability_over = float(structural_result["probability_over"])
        probability_under = float(structural_result["probability_under"])
        mean = float(structural_result["mean"])
        source = "directed_moneyline_fallback"
        source_label = "Modelo dirigido + moneyline (fallback)"
        model_id = "weekly_directed_raw"
        fallback_used = True
        diagnostics: dict[str, Any] = {
            "fallback_reason": "pinnacle_postdraft_total_missing"
        }
    else:
        pmf = list(pinnacle_reference["pmf"])
        probability_over = float(
            pinnacle_reference["probability_over_soft"]
        )
        probability_under = float(
            pinnacle_reference["probability_under_soft"]
        )
        mean = float(pinnacle_reference["mean"])
        source = "pinnacle_postdraft"
        source_label = "Pinnacle pós-draft"
        model_id = "market_implied_nb_exact"
        fallback_used = False
        diagnostics = dict(pinnacle_reference.get("diagnostics") or {})
    agreement = evaluate_model_agreement(
        request,
        structural_result,
        pinnacle_reference,
    )
    ev_over = probability_over * float(request["soft_odds_over"]) - 1
    ev_under = probability_under * float(request["soft_odds_under"]) - 1
    return {
        "prediction_source": source,
        "source_label": source_label,
        "model_id": model_id,
        "fallback_used": fallback_used,
        "pmf": pmf,
        "mean": mean,
        "median": _pmf_quantile(pmf, 0.5),
        "prediction_interval_90": [
            _pmf_quantile(pmf, 0.05),
            _pmf_quantile(pmf, 0.95),
        ],
        "probability_over": probability_over,
        "probability_under": probability_under,
        "fair_odds_over": 1 / probability_over,
        "fair_odds_under": 1 / probability_under,
        "ev_over": ev_over,
        "ev_under": ev_under,
        "preferred_side": _preferred_ev_side(ev_over, ev_under),
        "diagnostics": diagnostics,
        "model_agreement": agreement,
    }


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
        "no_vig_method": "proportional_normalization",
        "fundamental_probability_over_pinnacle_line": _probability_over(
            list(visible_result["pmf"]),
            float(line),
        ),
    }
    diagnostics["fundamental_market_probability_gap"] = (
        diagnostics["fundamental_probability_over_pinnacle_line"]
        - probability_over
    )
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
                    "log_mean_gap_directed_vs_market": math.log(
                        float(visible_result["mean"]) / exact_mean
                    ),
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
                        "team_a_implied_mean": team_means["team_a"],
                        "team_b_implied_mean": team_means["team_b"],
                        "team_total_sum": sum_team_means,
                        "team_a_implied_share": share_a,
                        "team_b_implied_share": 1 - share_a,
                        "team_total_sum_gap": sum_team_means
                        - row["diagnostics"]["implied_mean"],
                    }
                )
    return rows
