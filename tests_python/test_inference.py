import math
import json
from pathlib import Path

from app.lolkills_inference import (
    _model_mean,
    load_bundle,
    negative_binomial_pmf,
    predict,
)


def make_bundle():
    taxonomy = {}
    champion_samples = {}
    for index in range(10):
        name = f"C{index}"
        taxonomy[name] = {
            "tank": index == 0,
            "fighter": index == 1,
            "assassin": index == 2,
            "mage": index in (2, 3),
            "marksman": index == 4,
            "support": index == 5,
            "attack": 0.5,
            "defense": 0.5,
            "magic": 0.5,
            "difficulty": 0.5,
        }
        champion_samples[name] = 10
    return {
        "metadata": {"model_version": "test", "data_cutoff": "2026-01-01"},
        "model": {
            "theta": 10,
            "league_levels": ["LCK"],
            "feature_names": ["pace"],
            "coefficients": {"(Intercept)": math.log(25), "pace": 0},
            "scaling": {"pace": {"center": 0.8, "scale": 0.1}},
        },
        "teams": [
            {
                "key": "name:blue",
                "team_name": "Blue",
                "effective_team_games": 5,
                "hist_pace": 0.8,
            },
            {
                "key": "name:red",
                "team_name": "Red",
                "effective_team_games": 5,
                "hist_pace": 0.8,
            },
        ],
        "taxonomy": taxonomy,
        "champion_samples": champion_samples,
        "sample_limits": {
            "team_effective_games": 1,
            "champion_effective_games": 1,
        },
    }


def make_request():
    positions = ("top", "jng", "mid", "bot", "sup")
    return {
        "league": "LCK",
        "planned_at": "2026-08-01T12:00:00+00:00",
        "map_number": 1,
        "line": 24.5,
        "blue": {
            "team_name": "Blue",
            "champions": [
                {
                    "position": position,
                    "champion": f"C{index}",
                }
                for index, position in enumerate(positions)
            ],
        },
        "red": {
            "team_name": "Red",
            "champions": [
                {
                    "position": position,
                    "champion": f"C{index + 5}",
                }
                for index, position in enumerate(positions)
            ],
        },
    }


def test_negative_binomial_pmf_is_normalized():
    pmf = negative_binomial_pmf(25, 8)
    assert math.isclose(sum(pmf), 1.0)
    assert all(mass >= 0 for mass in pmf)


def test_prediction_contract_and_half_line():
    result = predict(make_request(), make_bundle())
    assert result["status"] == "ok"
    assert math.isclose(
        result["probability_over"] + result["probability_under"],
        1.0,
    )
    assert result["probability_push"] == 0
    assert math.isclose(result["mean"], 25)


def test_non_half_line_is_blocked():
    request = make_request()
    request["line"] = 25
    result = predict(request, make_bundle())
    assert result["status"] == "blocked"
    assert ".5" in result["reason"]


def test_exported_r_python_model_parity():
    bundle_path = Path("app_data/model_bundle.json")
    fixture_path = Path("app_data/parity_fixture.json")
    if not bundle_path.exists() or not fixture_path.exists():
        return
    bundle = load_bundle(bundle_path)
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    mean = _model_mean(
        fixture["league"],
        fixture["features"],
        bundle["model"],
    )
    pmf = negative_binomial_pmf(mean, bundle["model"]["theta"])
    assert math.isclose(
        mean,
        fixture["expected_mean"],
        rel_tol=fixture["tolerance"],
        abs_tol=fixture["tolerance"],
    )
    assert len(pmf) == len(fixture["expected_pmf"])
    assert max(
        abs(left - right)
        for left, right in zip(pmf, fixture["expected_pmf"])
    ) < fixture["tolerance"]
