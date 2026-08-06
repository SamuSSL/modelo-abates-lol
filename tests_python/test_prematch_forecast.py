import json
from pathlib import Path

import pytest

from app.prematch_forecast import (
    assess_soft_model_readiness,
    forecast_final_prematch,
    load_prematch_forecast_bundle,
)


ARTIFACT = Path(
    "artifacts/modeling-research/pinnacle-prematch-forecast-soft-open"
)


def test_python_forecast_matches_r_fixture():
    bundle = load_prematch_forecast_bundle(ARTIFACT / "forecast-bundle.json")
    fixture = json.loads((ARTIFACT / "parity-fixture.json").read_text(encoding="utf-8"))
    result = forecast_final_prematch(
        fixture["features"],
        fixture["soft_quote"]["line"],
        fixture["soft_quote"]["odds_over"],
        fixture["soft_quote"]["odds_under"],
        bundle,
    )
    assert result["predicted_last_mu"] == pytest.approx(
        fixture["expected"]["predicted_last_mu"], abs=1e-10
    )
    assert result["predicted_last_mu_low"] == pytest.approx(
        fixture["expected"]["predicted_last_mu_low"], abs=1e-10
    )
    assert result["predicted_last_mu_high"] == pytest.approx(
        fixture["expected"]["predicted_last_mu_high"], abs=1e-10
    )
    assert result["version"] == bundle["model_id"]
    assert result["ev_over"] == pytest.approx(
        result["probability_over"] * fixture["soft_quote"]["odds_over"] - 1
    )
    assert result["ev_under"] == pytest.approx(
        result["probability_under"] * fixture["soft_quote"]["odds_under"] - 1
    )
    assert result["action"] == "shadow_abstain"
    assert result["stake"] == 0


def test_unknown_league_uses_other_level():
    bundle = load_prematch_forecast_bundle(ARTIFACT / "forecast-bundle.json")
    fixture = json.loads((ARTIFACT / "parity-fixture.json").read_text(encoding="utf-8"))
    fixture["features"]["league_model"] = "NEW_LEAGUE"
    result = forecast_final_prematch(
        fixture["features"], 24.5, 1.95, 1.95, bundle
    )
    assert result["model_status"] == "shadow_only"


def test_model_b_requires_500_first_seen_quotes_and_three_leagues():
    quotes = [
        {
            "quote_id": str(index),
            "quote_stage": "first_seen",
            "league": ("LCK", "LPL", "LEC")[index % 3],
        }
        for index in range(500)
    ]
    readiness = assess_soft_model_readiness(quotes)
    assert readiness["ready_to_train_model_b"] is True
    assert readiness["development_rows"] == 300
    assert readiness["confirmation_rows"] == 200


def test_model_b_rejects_updates_as_training_gate():
    quotes = [
        {"quote_id": str(index), "quote_stage": "update", "league": "LCK"}
        for index in range(500)
    ]
    assert assess_soft_model_readiness(quotes)["ready_to_train_model_b"] is False


def test_model_b_counts_one_first_seen_per_game():
    quotes = [
        {
            "quote_id": str(index),
            "gameid": "same-game",
            "quote_stage": "first_seen",
            "league": "LCK",
        }
        for index in range(500)
    ]
    readiness = assess_soft_model_readiness(quotes)
    assert readiness["first_seen_quotes"] == 1
    assert readiness["ready_to_train_model_b"] is False
