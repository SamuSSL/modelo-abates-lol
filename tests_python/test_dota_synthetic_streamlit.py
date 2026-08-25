from __future__ import annotations

from app.dota_synthetic import load_dota_state, predict_dota_quote


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
