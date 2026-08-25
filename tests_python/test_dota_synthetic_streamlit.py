from __future__ import annotations

from datetime import datetime, timezone

from app.dota_synthetic import load_dota_state, predict_dota_quote
from app.dota_synthetic import _resolve_automatic_features, build_dota_quotes


def test_dota_streamlit_adapter_uses_promoted_pre_draft_bundle() -> None:
    state = load_dota_state()
    names = state["bundle"]["feature_names"]
    assert len(names) == 8
    result = predict_dota_quote(
        state,
        {name: 25.0 for name in names},
        {"line": 48.5, "odds_over": 1.90, "odds_under": 1.90},
    )
    assert result["model_id"] == "dota2-pinnacle-pre-draft-market-core_plus_recency_15d-v1"
    assert result["automatic_betting_approved"] is False
    assert result["line"] > 0


def test_dota_streamlit_adapter_rejects_leakage_features() -> None:
    state = load_dota_state()
    try:
        predict_dota_quote(state, {"side": 1.0})
    except ValueError as error:
        assert "proibidos" in str(error)
    else:
        raise AssertionError("A side não pode entrar no adapter Dota pré-draft.")


def test_dota_catalog_resolves_all_eight_features_without_manual_inputs() -> None:
    state = load_dota_state()
    league = next(row for row in state["catalog"]["leagues"] if len(row["teams"]) >= 2)
    team_one = league["teams"][0]["team_id"]
    team_two = league["teams"][1]["team_id"]
    features, metadata, error = _resolve_automatic_features(
        state["catalog"],
        str(league["source_league_id"]),
        str(team_one),
        str(team_two),
        1,
        datetime(2026, 8, 25, tzinfo=timezone.utc),
    )
    assert error is None
    assert features is not None
    assert len(features) == 8
    assert metadata["team_one_snapshot_match_id"]
    assert metadata["team_two_snapshot_match_id"]


def test_dota_quote_builder_preserves_primary_and_active_additional_quotes() -> None:
    primary = {
        "bookmaker": "Bet365",
        "line": 48.5,
        "odds_over": 1.90,
        "odds_under": 1.91,
    }
    additional = [
        {
            "enabled": True,
            "bookmaker": "KTO",
            "line": 47.5,
            "odds_over": 1.85,
            "odds_under": 1.95,
            "slot": 2,
        },
        {
            "enabled": False,
            "bookmaker": "",
            "line": 49.5,
            "odds_over": 1.88,
            "odds_under": 1.92,
            "slot": 3,
        },
    ]

    quotes = build_dota_quotes(primary, additional)

    assert quotes == [
        {"bookmaker": "Bet365", "line": 48.5, "odds_over": 1.90, "odds_under": 1.91, "slot": 1},
        {"bookmaker": "KTO", "line": 47.5, "odds_over": 1.85, "odds_under": 1.95, "slot": 2},
    ]
