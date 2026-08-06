import json
from pathlib import Path

import pytest

from app.synthetic_pinnacle import (
    build_team_pair_features,
    load_synthetic_pinnacle_bundle,
    predict_synthetic_pinnacle_from_features,
    predict_synthetic_pinnacle_quotes,
)


ARTIFACT = Path("artifacts/modeling-research/synthetic-pinnacle-direct-market-v2")


def test_r_python_synthetic_pinnacle_parity():
    bundle = load_synthetic_pinnacle_bundle(
        ARTIFACT / "synthetic-pinnacle-direct-bundle.json"
    )
    fixture = json.loads((ARTIFACT / "parity-fixture.json").read_text(encoding="utf-8"))
    quote = fixture["soft_quotes"][0]
    result = predict_synthetic_pinnacle_from_features(
        fixture["features"], fixture["features"]["league_model"],
        quote["line"], quote["odds_over"], quote["odds_under"], bundle,
    )
    for field in (
        "predicted_final_line", "predicted_final_probability_over",
        "predicted_final_odds_over", "predicted_final_odds_under",
    ):
        assert result[field] == pytest.approx(
            fixture["expected"][field], abs=1e-9
        )
    assert result["automatic_betting_approved"] is False


def test_pair_features_are_side_invariant():
    ratings = {}
    for window in ("season", "last15"):
        ratings.update({
            f"{window}_team_games": 10,
            f"{window}_attack_ratio": 1.1,
            f"{window}_concession_ratio": 0.9,
            f"{window}_kpm_ratio": 1.1,
            f"{window}_dpm_ratio": 0.9,
            f"{window}_duration_ratio": 1.0,
            f"{window}_total_kills_sd_ratio": 1.0,
            f"{window}_league_kills_per_map": 15,
            f"{window}_league_deaths_per_map": 15,
            f"{window}_league_duration": 30,
        })
    first = {"hist_pace": 1.0, "ratings": ratings}
    second = {"hist_pace": 1.2, "ratings": {**ratings, "last15_attack_ratio": 0.8}}
    assert build_team_pair_features(first, second, 2) == build_team_pair_features(
        second, first, 2
    )


def test_contract_has_no_prohibited_market_inputs():
    bundle = load_synthetic_pinnacle_bundle(
        ARTIFACT / "synthetic-pinnacle-direct-bundle.json"
    )
    assert bundle["prohibited_features"] == [
        "moneyline", "side", "soft_line", "soft_odds", "draft"
    ]
    assert not any(
        prohibited in feature.lower()
        for feature in bundle["feature_names"]
        for prohibited in ("moneyline", "odds", "soft", "blue", "red", "side")
    )


def test_three_soft_quotes_use_the_same_direct_pinnacle_forecast():
    bundle = load_synthetic_pinnacle_bundle("app_data/synthetic_pinnacle_bundle.json")
    team_ids = list(bundle["team_roster_features"])
    ratings = {}
    for window in ("season", "last15"):
        ratings.update({
            f"{window}_team_games": 20,
            f"{window}_attack_ratio": 1.0,
            f"{window}_concession_ratio": 1.0,
            f"{window}_kpm_ratio": 1.0,
            f"{window}_dpm_ratio": 1.0,
            f"{window}_duration_ratio": 1.0,
            f"{window}_total_kills_sd_ratio": 1.0,
            f"{window}_league_kills_per_map": 15,
            f"{window}_league_deaths_per_map": 15,
            f"{window}_league_duration": 30,
        })
    first = {"team_id": team_ids[0], "hist_pace": 1.0, "ratings": ratings}
    second = {"team_id": team_ids[1], "hist_pace": 1.0, "ratings": ratings}
    quotes = [
        {"line": 24.5, "odds_over": 1.90, "odds_under": 1.90},
        {"line": 25.5, "odds_over": 2.00, "odds_under": 1.80},
        {"line": 26.5, "odds_over": 2.10, "odds_under": 1.72},
    ]
    results = predict_synthetic_pinnacle_quotes(
        first, second, bundle["league_levels"][0], 1, quotes, bundle
    )
    assert len(results) == 3
    assert len({result["predicted_final_line"] for result in results}) == 1
    assert results[0]["probability_over"] > results[2]["probability_over"]
