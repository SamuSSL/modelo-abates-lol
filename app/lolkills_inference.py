from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np

from app.predraft_contract import (
    PredraftContractError,
    evaluate_operational_gate,
    evaluate_roster_gate,
    legacy_request_from_predraft,
    normalize_predraft_request,
)


POSITIONS = ("top", "jng", "mid", "bot", "sup")


class PredictionBlocked(ValueError):
    pass


def _feature_names(model: dict[str, Any]) -> list[str]:
    names = model.get("feature_names", [])
    return [names] if isinstance(names, str) else list(names)


def load_bundle(path: str | Path) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _entity_key(identifier: str | None, name: str, position: str = "") -> str:
    identity = f"id:{identifier}" if identifier else f"name:{name.strip().lower()}"
    return f"{identity}|{position.lower()}" if position else identity


def _quantile(pmf: list[float], probability: float) -> int:
    cumulative = 0.0
    for value, mass in enumerate(pmf):
        cumulative += mass
        if cumulative >= probability:
            return value
    return len(pmf) - 1


def negative_binomial_pmf(
    mean: float,
    theta: float,
    tail_tolerance: float = 1e-10,
) -> list[float]:
    if not math.isfinite(mean) or mean <= 0:
        raise ValueError("A média prevista precisa ser positiva.")
    if not math.isfinite(theta) or theta <= 0:
        raise ValueError("O parâmetro de dispersão precisa ser positivo.")
    probability = theta / (theta + mean)
    mass = probability**theta
    pmf = [mass]
    cumulative = mass
    value = 0
    while cumulative < 1 - tail_tolerance or value < mean:
        value += 1
        mass *= ((value - 1 + theta) / value) * (mean / (theta + mean))
        pmf.append(mass)
        cumulative += mass
        if value > 1000:
            raise RuntimeError("A distribuição não convergiu.")
    total = sum(pmf)
    return [mass / total for mass in pmf]


def _composition_scores(
    champions: list[str],
    taxonomy: dict[str, dict[str, Any]],
) -> dict[str, float]:
    if len(champions) != 5 or len(set(champions)) != 5:
        raise PredictionBlocked("Cada equipe precisa de cinco campeões únicos.")
    try:
        rows = [taxonomy[champion] for champion in champions]
    except KeyError as error:
        raise PredictionBlocked(
            f"Campeão sem taxonomia: {error.args[0]}. Não apostar."
        ) from error

    def average(values: list[float]) -> float:
        return sum(values) / len(values)

    return {
        "frontline_score": average(
            [
                0.6 * float(row["defense"])
                + 0.4 * float(bool(row["tank"]) or bool(row["fighter"]))
                for row in rows
            ]
        ),
        "damage_score": average([float(row["attack"]) for row in rows]),
        "magic_score": average([float(row["magic"]) for row in rows]),
        "burst_score": average(
            [float(bool(row["assassin"]) or bool(row["mage"])) for row in rows]
        ),
        "utility_score": average(
            [float(bool(row["support"]) or bool(row["tank"])) for row in rows]
        ),
        "execution_difficulty": average(
            [float(row["difficulty"]) for row in rows]
        ),
    }


def _lookup_entities(
    request: dict[str, Any],
    bundle: dict[str, Any],
) -> tuple[list[dict[str, Any]], list[str]]:
    warnings: list[str] = []
    team_lookup = {row["key"]: row for row in bundle["teams"]}
    teams: list[dict[str, Any]] = []
    if request["blue"]["team_name"] == request["red"]["team_name"]:
        raise PredictionBlocked("As equipes azul e vermelha devem ser diferentes.")
    for side in ("blue", "red"):
        team = request[side]
        key = _entity_key(team.get("team_id"), team["team_name"])
        if key not in team_lookup:
            raise PredictionBlocked(
                f"Pouca amostra para {team['team_name']}. Não apostar."
            )
        teams.append(team_lookup[key])
    return teams, warnings


def derive_features(
    request: dict[str, Any],
    bundle: dict[str, Any],
) -> tuple[dict[str, float], list[str]]:
    teams, warnings = _lookup_entities(request, bundle)
    limits = bundle["sample_limits"]
    for team in teams:
        if team["effective_team_games"] < limits["team_effective_games"]:
            raise PredictionBlocked(
                f"Pouca amostra para {team['team_name']}. Não apostar."
            )
    average = lambda values: sum(values) / len(values)
    features = {
        "pace": average([row["hist_pace"] for row in teams]),
    }
    draft_features = {
        "draft_frontline",
        "draft_burst",
        "draft_frontline_imbalance",
    }
    if draft_features.intersection(_feature_names(bundle["model"])):
        all_champions: list[str] = []
        for side in ("blue", "red"):
            side_champions = request[side].get("champions", [])
            if [row["position"] for row in side_champions] != list(POSITIONS):
                raise PredictionBlocked(
                    "As posições devem ser top, jng, mid, bot e sup."
                )
            all_champions.extend(
                row["champion"] for row in side_champions
            )
        if len(set(all_champions)) != 10:
            raise PredictionBlocked("O draft não pode repetir campeões.")
        champion_samples = bundle["champion_samples"]
        for champion in all_champions:
            if (
                champion_samples.get(champion, 0)
                < limits["champion_effective_games"]
            ):
                raise PredictionBlocked(
                    f"Pouca amostra para {champion}. Não apostar."
                )
        taxonomy = bundle["taxonomy"]
        blue_scores = _composition_scores(
            all_champions[:5],
            taxonomy,
        )
        red_scores = _composition_scores(
            all_champions[5:],
            taxonomy,
        )
        features.update(
            {
                "draft_frontline": average(
                    [
                        blue_scores["frontline_score"],
                        red_scores["frontline_score"],
                    ]
                ),
                "draft_burst": average(
                    [
                        blue_scores["burst_score"],
                        red_scores["burst_score"],
                    ]
                ),
                "draft_frontline_imbalance": abs(
                    blue_scores["frontline_score"]
                    - red_scores["frontline_score"]
                ),
            }
        )
    return features, warnings


def _model_mean(
    league: str,
    features: dict[str, float],
    model: dict[str, Any],
) -> float:
    if league not in model["league_levels"]:
        raise PredictionBlocked(f"Liga não suportada: {league}.")
    linear = float(model["coefficients"]["(Intercept)"])
    league_term = f"league_canonical{league}"
    linear += float(model["coefficients"].get(league_term, 0.0))
    for feature in _feature_names(model):
        scaling = model["scaling"][feature]
        standardized = (
            float(features[feature]) - float(scaling["center"])
        ) / float(scaling["scale"])
        linear += float(model["coefficients"][feature]) * standardized
    return math.exp(linear)


def _linear_predictor(
    coefficients: dict[str, Any],
    league: str,
    features: dict[str, float],
) -> float:
    value = float(coefficients.get("(Intercept)", 0.0))
    value += float(
        coefficients.get(f"league_canonical{league}", 0.0)
    )
    for name, feature_value in features.items():
        value += float(coefficients.get(name, 0.0)) * float(feature_value)
    return value


def _moneyline_probabilities(
    request: dict[str, Any],
) -> tuple[float, float]:
    blue_odds = request.get("moneyline_blue_odds")
    red_odds = request.get("moneyline_red_odds")
    if blue_odds is None or red_odds is None:
        raise PredictionBlocked(
            "Informe as duas odds de moneyline do mapa. Não apostar."
        )
    blue_odds = float(blue_odds)
    red_odds = float(red_odds)
    if (
        not math.isfinite(blue_odds)
        or not math.isfinite(red_odds)
        or blue_odds <= 1
        or red_odds <= 1
    ):
        raise PredictionBlocked(
            "As duas odds de moneyline precisam ser decimais e maiores que 1."
        )
    raw_blue = 1 / blue_odds
    raw_red = 1 / red_odds
    total = raw_blue + raw_red
    return raw_blue / total, raw_red / total


def _directed_features(
    request: dict[str, Any],
    bundle: dict[str, Any],
) -> tuple[dict[str, float], list[dict[str, Any]], list[str]]:
    teams, warnings = _lookup_entities(request, bundle)
    limits = bundle["sample_limits"]
    for team in teams:
        if team["effective_team_games"] < limits["team_effective_games"]:
            raise PredictionBlocked(
                f"Pouca amostra para {team['team_name']}. Não apostar."
            )
    league = request["league"]
    if league not in bundle["model"]["league_levels"]:
        raise PredictionBlocked(f"Liga não suportada: {league}.")
    if any(team.get("league_canonical") != league for team in teams):
        raise PredictionBlocked(
            "As equipes precisam pertencer à liga selecionada."
        )

    blue, red = teams
    windows = list(bundle["model"]["windows"])
    durations: list[float] = []
    duration_imbalances: list[float] = []
    volatility: list[float] = []
    features: dict[str, float] = {
        "pace": (
            float(blue["hist_pace"]) + float(red["hist_pace"])
        ) / 2,
        "map_2": float(int(request["map_number"]) == 2),
        "map_3": float(int(request["map_number"]) == 3),
        "map_4_plus": float(int(request["map_number"]) >= 4),
    }
    for window in windows:
        blue_ratings = blue["ratings"]
        red_ratings = red["ratings"]
        blue_duration_ratio = float(
            blue_ratings[f"{window}_duration_ratio"]
        )
        red_duration_ratio = float(
            red_ratings[f"{window}_duration_ratio"]
        )
        league_duration = math.sqrt(
            float(blue_ratings[f"{window}_league_duration"])
            * float(red_ratings[f"{window}_league_duration"])
        )
        duration = league_duration * math.sqrt(
            blue_duration_ratio * red_duration_ratio
        )
        durations.append(duration)
        duration_imbalances.append(
            abs(
                math.log(blue_duration_ratio)
                - math.log(red_duration_ratio)
            )
        )
        volatility.append(
            math.sqrt(
                float(
                    blue_ratings[
                        f"{window}_total_kills_sd_ratio"
                    ]
                )
                * float(
                    red_ratings[
                        f"{window}_total_kills_sd_ratio"
                    ]
                )
            )
        )
        features[f"duration_{window}"] = duration
    features["duration_level"] = math.exp(
        sum(math.log(value) for value in durations) / len(durations)
    )
    features["duration_imbalance"] = (
        sum(duration_imbalances) / len(duration_imbalances)
    )
    features["team_volatility"] = sum(volatility) / len(volatility)
    return features, teams, warnings


def _directed_rate(
    side: str,
    teams: list[dict[str, Any]],
    features: dict[str, float],
    model: dict[str, Any],
    league: str,
) -> float:
    team_index = 0 if side == "blue" else 1
    opponent_index = 1 - team_index
    team = teams[team_index]
    opponent = teams[opponent_index]
    directed = {
        "pace": features["pace"],
        "map_2": features["map_2"],
        "map_3": features["map_3"],
        "map_4_plus": features["map_4_plus"],
    }
    baseline_logs: list[float] = []
    for window in model["windows"]:
        directed[f"own_kpm_{window}"] = math.log(
            float(team["ratings"][f"{window}_kpm_ratio"])
        )
        directed[f"opponent_dpm_{window}"] = math.log(
            float(opponent["ratings"][f"{window}_dpm_ratio"])
        )
        baseline_logs.append(
            math.log(
                float(team["ratings"][f"{window}_league_kpm"])
            )
        )
    linear = _linear_predictor(
        model["intensity"]["coefficients"],
        league,
        directed,
    )
    return math.exp(linear + sum(baseline_logs) / len(baseline_logs))


def _lognormal_nb_mixture_pmf(
    duration_meanlog: float,
    duration_sdlog: float,
    total_rate: float,
    theta: float,
    nodes: int,
) -> tuple[list[float], float]:
    quadrature_nodes, quadrature_weights = (
        np.polynomial.hermite.hermgauss(int(nodes))
    )
    normalized_weights = quadrature_weights / math.sqrt(math.pi)
    component_pmfs: list[tuple[float, list[float]]] = []
    expected_mean = 0.0
    maximum_length = 0
    for node, weight in zip(
        quadrature_nodes.tolist(),
        normalized_weights.tolist(),
    ):
        duration = math.exp(
            duration_meanlog
            + math.sqrt(2) * duration_sdlog * float(node)
        )
        component_mean = duration * total_rate
        expected_mean += float(weight) * component_mean
        component = negative_binomial_pmf(component_mean, theta)
        component_pmfs.append((float(weight), component))
        maximum_length = max(maximum_length, len(component))
    mixture = [0.0] * maximum_length
    for weight, component in component_pmfs:
        for index, mass in enumerate(component):
            mixture[index] += weight * mass
    total = sum(mixture)
    return [mass / total for mass in mixture], expected_mean


def _predict_directed_moneyline(
    request: dict[str, Any],
    bundle: dict[str, Any],
    line: float,
) -> dict[str, Any]:
    model = bundle["model"]
    features, teams, warnings = _directed_features(request, bundle)
    p_blue, p_red = _moneyline_probabilities(request)
    favorite_imbalance = abs(math.log(p_blue / p_red))
    favorite_imbalance_squared = favorite_imbalance**2
    duration_features = {
        name: features[name]
        for name in model["duration"]["feature_names"]
    }
    duration_meanlog = _linear_predictor(
        model["duration"]["coefficients"],
        request["league"],
        duration_features,
    )
    duration_correction = model["moneyline"][
        "duration_coefficients"
    ]
    duration_meanlog += (
        float(duration_correction.get("(Intercept)", 0.0))
        + float(
            duration_correction.get("favorite_imbalance", 0.0)
        )
        * favorite_imbalance
        + float(
            duration_correction.get(
                "favorite_imbalance_squared",
                0.0,
            )
        )
        * favorite_imbalance_squared
    )

    base_blue_rate = _directed_rate(
        "blue",
        teams,
        features,
        model,
        request["league"],
    )
    base_red_rate = _directed_rate(
        "red",
        teams,
        features,
        model,
        request["league"],
    )
    correction = model["moneyline"]["intensity_coefficients"]

    def corrected_rate(base_rate: float, probability: float) -> float:
        win_logit = math.log(probability / (1 - probability))
        correction_linear = (
            float(correction.get("(Intercept)", 0.0))
            + float(correction.get("win_logit", 0.0)) * win_logit
            + float(
                correction.get("favorite_imbalance", 0.0)
            )
            * favorite_imbalance
            + float(
                correction.get(
                    "win_logit_times_imbalance",
                    0.0,
                )
            )
            * win_logit
            * favorite_imbalance
            + float(
                correction.get(
                    "favorite_imbalance_squared",
                    0.0,
                )
            )
            * favorite_imbalance_squared
        )
        return base_rate * math.exp(correction_linear)

    blue_rate = corrected_rate(base_blue_rate, p_blue)
    red_rate = corrected_rate(base_red_rate, p_red)
    total_rate = blue_rate + red_rate
    duration_sdlog = float(model["duration"]["residual_sd_log"])
    pmf, mean = _lognormal_nb_mixture_pmf(
        duration_meanlog,
        duration_sdlog,
        total_rate,
        float(model["theta"]),
        int(model.get("quadrature_nodes", 32)),
    )
    duration_mean = math.exp(
        duration_meanlog + 0.5 * duration_sdlog**2
    )
    duration_median = math.exp(duration_meanlog)
    duration_sd = duration_mean * math.sqrt(
        math.exp(duration_sdlog**2) - 1
    )
    blue_share = blue_rate / total_rate
    features.update(
        {
            "p_blue_no_vig": p_blue,
            "p_red_no_vig": p_red,
            "favorite_probability": max(p_blue, p_red),
            "favorite_imbalance": favorite_imbalance,
            "duration_mean": duration_mean,
            "duration_median": duration_median,
            "duration_sd": duration_sd,
            "blue_rate": blue_rate,
            "red_rate": red_rate,
            "blue_share": blue_share,
            "blue_mean": mean * blue_share,
            "red_mean": mean * (1 - blue_share),
            "allocation_concentration": float(
                model["allocation_concentration"]
            ),
        }
    )
    under_max = math.floor(line)
    probability_under = sum(pmf[: under_max + 1])
    probability_over = 1 - probability_under
    result: dict[str, Any] = {
        "status": "ok",
        "prediction_id": _prediction_id(request),
        "mean": mean,
        "median": _quantile(pmf, 0.5),
        "prediction_interval_90": [
            _quantile(pmf, 0.05),
            _quantile(pmf, 0.95),
        ],
        "pmf": pmf,
        "probability_over": probability_over,
        "probability_under": probability_under,
        "probability_push": 0.0,
        "no_vig_method": "proportional_normalization",
        "fair_odds_over": 1 / probability_over,
        "fair_odds_under": 1 / probability_under,
        "features": features,
        "warnings": warnings,
        "model_version": bundle["metadata"]["model_version"],
        "model_candidate": bundle["metadata"][
            "selected_candidate_id"
        ],
        "model_status": bundle["metadata"].get("model_status"),
        "data_cutoff": bundle["metadata"]["data_cutoff"],
    }
    odds_over = request.get("odds_over")
    odds_under = request.get("odds_under")
    if odds_over:
        result["ev_over"] = probability_over * float(odds_over) - 1
    if odds_under:
        result["ev_under"] = probability_under * float(odds_under) - 1
    if odds_over and odds_under:
        raw_over = 1 / float(odds_over)
        raw_under = 1 / float(odds_under)
        total = raw_over + raw_under
        result["no_vig_probability_over"] = raw_over / total
        result["no_vig_probability_under"] = raw_under / total
    return result


def _prediction_id(request: dict[str, Any]) -> str:
    identity = "|".join(
        [
            request["league"],
            request["planned_at"],
            request["blue"]["team_name"],
            request["red"]["team_name"],
            str(request["map_number"]),
        ]
    )
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()[:24]


def _predraft_prediction_id(request: dict[str, Any]) -> str:
    teams = sorted(
        [request["team_a"]["team_name"], request["team_b"]["team_name"]]
    )
    identity = "|".join(
        [
            request["league"],
            request["planned_at"],
            teams[0],
            teams[1],
            str(request["map_number"]),
        ]
    )
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()[:24]


def _average_pmfs(first: list[float], second: list[float]) -> list[float]:
    size = max(len(first), len(second))
    averaged = [
        0.5
        * (
            (first[index] if index < len(first) else 0.0)
            + (second[index] if index < len(second) else 0.0)
        )
        for index in range(size)
    ]
    total = sum(averaged)
    return [mass / total for mass in averaged]


def _predict_predraft(
    request: dict[str, Any],
    bundle: dict[str, Any],
) -> dict[str, Any]:
    normalized = normalize_predraft_request(request)
    first = predict(legacy_request_from_predraft(normalized), bundle)
    swapped = predict(
        legacy_request_from_predraft(normalized, swap=True),
        bundle,
    )
    if first.get("status") != "ok" or swapped.get("status") != "ok":
        reasons = [
            row.get("reason", "Previsao fundamental bloqueada.")
            for row in (first, swapped)
            if row.get("status") != "ok"
        ]
        raise PredictionBlocked(" ".join(dict.fromkeys(reasons)))

    pmf = _average_pmfs(first["pmf"], swapped["pmf"])
    line = float(normalized["soft_line"])
    probability_under = sum(pmf[: math.floor(line) + 1])
    probability_over = 1 - probability_under
    first_features = first.get("features") or {}
    swapped_features = swapped.get("features") or {}
    features = dict(first_features)
    average_feature_names = (
        "duration_mean",
        "duration_median",
        "duration_sd",
        "favorite_probability",
        "favorite_imbalance",
    )
    for name in average_feature_names:
        if name in first_features and name in swapped_features:
            features[name] = 0.5 * (
                float(first_features[name]) + float(swapped_features[name])
            )
    features["team_a_mean"] = 0.5 * (
        float(first_features.get("blue_mean", 0.0))
        + float(swapped_features.get("red_mean", 0.0))
    )
    features["team_b_mean"] = 0.5 * (
        float(first_features.get("red_mean", 0.0))
        + float(swapped_features.get("blue_mean", 0.0))
    )
    features["p_team_a_no_vig"] = 0.5 * (
        float(first_features.get("p_blue_no_vig", 0.0))
        + float(swapped_features.get("p_red_no_vig", 0.0))
    )
    features["p_team_b_no_vig"] = 1 - features["p_team_a_no_vig"]
    features["order_symmetrized"] = True
    roster_gate = evaluate_roster_gate(
        normalized,
        bundle.get("roster_catalog"),
    )
    warnings = list(dict.fromkeys(
        list(first.get("warnings") or [])
        + list(swapped.get("warnings") or [])
    ))
    operational_gate = evaluate_operational_gate(
        normalized,
        bundle.get("metadata") or {},
    )
    lead_minutes = operational_gate["prediction_lead_minutes"]
    bet_block_reasons = list(dict.fromkeys(
        roster_gate["reasons"] + operational_gate["reasons"]
    ))
    mean = sum(index * mass for index, mass in enumerate(pmf))
    result: dict[str, Any] = {
        "status": "ok",
        "bet_status": "blocked" if bet_block_reasons else "allowed",
        "bet_block_reasons": bet_block_reasons,
        "prediction_id": _predraft_prediction_id(normalized),
        "contract": "predraft_v1",
        "mode": (
            "market_available"
            if normalized.get("pinnacle_total_line") is not None
            else "fundamental_fallback"
        ),
        "mean": mean,
        "median": _quantile(pmf, 0.5),
        "prediction_interval_90": [
            _quantile(pmf, 0.05),
            _quantile(pmf, 0.95),
        ],
        "pmf": pmf,
        "probability_over": probability_over,
        "probability_under": probability_under,
        "probability_push": 0.0,
        "no_vig_method": "proportional_normalization",
        "fair_odds_over": 1 / probability_over,
        "fair_odds_under": 1 / probability_under,
        "ev_over": probability_over * normalized["soft_odds_over"] - 1,
        "ev_under": probability_under * normalized["soft_odds_under"] - 1,
        "features": features,
        "roster_gate": roster_gate,
        "operational_gate": operational_gate,
        "prediction_lead_minutes": lead_minutes,
        "warnings": warnings,
        "model_version": bundle["metadata"]["model_version"],
        "model_candidate": bundle["metadata"].get("selected_candidate_id"),
        "model_status": bundle["metadata"].get("model_status"),
        "prospective_protocol_id": bundle["metadata"].get(
            "prospective_protocol_id"
        ),
        "data_cutoff": bundle["metadata"]["data_cutoff"],
    }
    no_vig_over = 1 / normalized["soft_odds_over"]
    no_vig_under = 1 / normalized["soft_odds_under"]
    no_vig_total = no_vig_over + no_vig_under
    result["no_vig_probability_over"] = no_vig_over / no_vig_total
    result["no_vig_probability_under"] = no_vig_under / no_vig_total
    return result


def predict(request: dict[str, Any], bundle: dict[str, Any]) -> dict[str, Any]:
    try:
        if "team_a" in request or "team_b" in request:
            return _predict_predraft(request, bundle)
        line = float(request["line"])
        if not math.isclose(line % 1, 0.5):
            raise PredictionBlocked("A linha precisa terminar em .5.")
        datetime.fromisoformat(request["planned_at"].replace("Z", "+00:00"))
        if bundle["model"].get("type") == "directed_moneyline":
            return _predict_directed_moneyline(
                request,
                bundle,
                line,
            )
        features, warnings = derive_features(request, bundle)
        mean = _model_mean(request["league"], features, bundle["model"])
        pmf = negative_binomial_pmf(mean, float(bundle["model"]["theta"]))
        under_max = math.floor(line)
        probability_under = sum(pmf[: under_max + 1])
        probability_over = 1 - probability_under
        result: dict[str, Any] = {
            "status": "ok",
            "prediction_id": _prediction_id(request),
            "mean": mean,
            "median": _quantile(pmf, 0.5),
            "prediction_interval_90": [
                _quantile(pmf, 0.05),
                _quantile(pmf, 0.95),
            ],
            "pmf": pmf,
            "probability_over": probability_over,
            "probability_under": probability_under,
            "probability_push": 0.0,
            "fair_odds_over": 1 / probability_over,
            "fair_odds_under": 1 / probability_under,
            "features": features,
            "warnings": warnings,
            "model_version": bundle["metadata"]["model_version"],
            "data_cutoff": bundle["metadata"]["data_cutoff"],
        }
        odds_over = request.get("odds_over")
        odds_under = request.get("odds_under")
        if odds_over:
            result["ev_over"] = probability_over * float(odds_over) - 1
        if odds_under:
            result["ev_under"] = probability_under * float(odds_under) - 1
        if odds_over and odds_under:
            raw_over = 1 / float(odds_over)
            raw_under = 1 / float(odds_under)
            total = raw_over + raw_under
            result["no_vig_probability_over"] = raw_over / total
            result["no_vig_probability_under"] = raw_under / total
        return result
    except (PredictionBlocked, PredraftContractError, KeyError, TypeError) as error:
        return {
            "status": "blocked",
            "reason": str(error),
            "probability_push": 0.0,
            "model_version": bundle["metadata"]["model_version"],
            "data_cutoff": bundle["metadata"]["data_cutoff"],
        }
