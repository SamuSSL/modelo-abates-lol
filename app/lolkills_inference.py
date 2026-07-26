from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


POSITIONS = ("top", "jng", "mid", "bot", "sup")


class PredictionBlocked(ValueError):
    pass


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
) -> tuple[list[dict[str, Any]], list[str], list[str]]:
    warnings: list[str] = []
    team_lookup = {row["key"]: row for row in bundle["teams"]}
    teams: list[dict[str, Any]] = []
    champions: list[str] = []
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
        side_champions = team["champions"]
        if [row["position"] for row in side_champions] != list(POSITIONS):
            raise PredictionBlocked("As posições devem ser top, jng, mid, bot e sup.")
        champions.extend(row["champion"] for row in side_champions)
    return teams, champions, warnings


def derive_features(
    request: dict[str, Any],
    bundle: dict[str, Any],
) -> tuple[dict[str, float], list[str]]:
    teams, all_champions, warnings = _lookup_entities(request, bundle)
    limits = bundle["sample_limits"]
    for team in teams:
        if team["effective_team_games"] < limits["team_effective_games"]:
            raise PredictionBlocked(
                f"Pouca amostra para {team['team_name']}. Não apostar."
            )
    if len(set(all_champions)) != 10:
        raise PredictionBlocked("O draft não pode repetir campeões.")
    champion_samples = bundle["champion_samples"]
    for champion in all_champions:
        if champion_samples.get(champion, 0) < limits["champion_effective_games"]:
            raise PredictionBlocked(
                f"Pouca amostra para {champion}. Não apostar."
            )
    taxonomy = bundle["taxonomy"]
    blue_scores = _composition_scores(
        [row["champion"] for row in request["blue"]["champions"]],
        taxonomy,
    )
    red_scores = _composition_scores(
        [row["champion"] for row in request["red"]["champions"]],
        taxonomy,
    )
    average = lambda values: sum(values) / len(values)
    features = {
        "pace": average([row["hist_pace"] for row in teams]),
        "draft_frontline": average(
            [blue_scores["frontline_score"], red_scores["frontline_score"]]
        ),
        "draft_burst": average(
            [blue_scores["burst_score"], red_scores["burst_score"]]
        ),
        "draft_frontline_imbalance": abs(
            blue_scores["frontline_score"] - red_scores["frontline_score"]
        ),
    }
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
    for feature in model["feature_names"]:
        scaling = model["scaling"][feature]
        standardized = (
            float(features[feature]) - float(scaling["center"])
        ) / float(scaling["scale"])
        linear += float(model["coefficients"][feature]) * standardized
    return math.exp(linear)


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


def predict(request: dict[str, Any], bundle: dict[str, Any]) -> dict[str, Any]:
    try:
        line = float(request["line"])
        if not math.isclose(line % 1, 0.5):
            raise PredictionBlocked("A linha precisa terminar em .5.")
        datetime.fromisoformat(request["planned_at"].replace("Z", "+00:00"))
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
    except PredictionBlocked as error:
        return {
            "status": "blocked",
            "reason": str(error),
            "probability_push": 0.0,
            "model_version": bundle["metadata"]["model_version"],
            "data_cutoff": bundle["metadata"]["data_cutoff"],
        }
