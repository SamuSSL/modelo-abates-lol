from __future__ import annotations

import json
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import streamlit as st

from app.dota_inference import PROHIBITED_FEATURES, load_bundle, predict


DOTA_BUNDLE_PATH = Path("app_data/dota2_pinnacle_pre_draft_bundle.json")
DOTA_DECISIONS_PATH = Path("app_data/dota_manual_comparisons.jsonl")
FEATURE_LABELS = {
    "team_one_kills_for": "Equipe 1 · kills próprias históricas",
    "team_one_kills_against": "Equipe 1 · kills cedidas históricas",
    "team_two_kills_for": "Equipe 2 · kills próprias históricas",
    "team_two_kills_against": "Equipe 2 · kills cedidas históricas",
    "team_one_kills_for_recency_15d": "Equipe 1 · kills próprias · meia-vida 15 dias",
    "team_one_kills_against_recency_15d": "Equipe 1 · kills cedidas · meia-vida 15 dias",
    "team_two_kills_for_recency_15d": "Equipe 2 · kills próprias · meia-vida 15 dias",
    "team_two_kills_against_recency_15d": "Equipe 2 · kills cedidas · meia-vida 15 dias",
}


def load_dota_state() -> dict[str, Any]:
    bundle = load_bundle(DOTA_BUNDLE_PATH)
    return {"bundle": bundle, "bundle_path": DOTA_BUNDLE_PATH}


def predict_dota_quote(
    state: dict[str, Any],
    features: dict[str, float],
    soft_quote: dict[str, float] | None = None,
) -> dict[str, Any]:
    invalid = set(features).intersection(PROHIBITED_FEATURES)
    if invalid:
        raise ValueError(f"Inputs proibidos no contrato pré-draft: {sorted(invalid)}")
    bundle = state["bundle"]
    feature_names = set(bundle.get("feature_names", []))
    prediction = predict(bundle, {name: features.get(name) for name in feature_names})
    prediction["model_id"] = bundle.get("model_id")
    prediction["automatic_betting_approved"] = False
    prediction["confidence"] = "model_only"
    if soft_quote is None:
        return prediction
    line = float(soft_quote["line"])
    odds_over = float(soft_quote["odds_over"])
    odds_under = float(soft_quote["odds_under"])
    if not math.isclose(line % 1, 0.5, abs_tol=1e-12):
        raise ValueError("A linha Dota deve terminar em .5.")
    if odds_over <= 1.0 or odds_under <= 1.0:
        raise ValueError("As odds Dota devem ser maiores que 1.00.")
    prediction["soft_quote"] = {
        "line": line,
        "odds_over": odds_over,
        "odds_under": odds_under,
    }
    if abs(line - float(prediction["line"])) < 0.26:
        prediction["ev_over"] = float(prediction["probability_over"]) * odds_over - 1.0
        prediction["ev_under"] = float(prediction["probability_under"]) * odds_under - 1.0
        prediction["ev_status"] = "same_line"
    else:
        prediction["ev_over"] = None
        prediction["ev_under"] = None
        prediction["ev_status"] = "line_mismatch"
    return prediction


def _append_manual_comparison(payload: dict[str, Any]) -> None:
    record = {
        "game": "Dota 2",
        "bundle_id": payload["prediction"].get("model_id"),
        "recorded_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "inputs": payload["inputs"],
        "prediction": payload["prediction"],
        "automatic_betting_approved": False,
        "status": "manual_comparison_pending_settlement",
    }
    DOTA_DECISIONS_PATH.parent.mkdir(parents=True, exist_ok=True)
    with DOTA_DECISIONS_PATH.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
        handle.write("\n")


def render_dota_tab(state: dict[str, Any]) -> dict[str, Any] | None:
    st.header("Dota 2 · Pinnacle Sintética")
    st.caption("Modelo pré-draft de linha principal e preços finais para comparação manual com soft book.")
    st.warning("Dota 2 · pré-draft · side-agnostic · sem heróis/draft/eventos · sem aposta automática.")
    feature_names = list(state["bundle"].get("feature_names", []))
    if len(feature_names) != 8:
        st.error("Bundle Dota incompatível: a aba exige as 8 features promovidas.")
        return None
    with st.form("dota_synthetic_prediction"):
        metadata_columns = st.columns(4)
        team_one = metadata_columns[0].text_input("Equipe Dota 2 1", key="dota_team_one")
        team_two = metadata_columns[1].text_input("Equipe Dota 2 2", key="dota_team_two")
        competition = metadata_columns[2].text_input("Competição / snapshot Dota", key="dota_competition")
        map_number = metadata_columns[3].number_input("Mapa Dota", min_value=1, max_value=7, value=1, step=1, key="dota_map_number")
        st.subheader("Features históricas point-in-time")
        feature_columns = st.columns(2)
        feature_input: dict[str, float] = {}
        for index, name in enumerate(feature_names):
            feature_input[name] = feature_columns[index % 2].number_input(
                FEATURE_LABELS.get(name, name), min_value=0.0, value=25.0,
                step=0.1, key=f"dota_feature_{name}",
            )
        st.subheader("Cotação soft")
        quote_columns = st.columns(3)
        soft_line = quote_columns[0].number_input("Linha Dota", min_value=0.5, value=48.5, step=1.0, key="dota_soft_line")
        soft_over = quote_columns[1].number_input("Odd Over Dota", min_value=1.01, value=1.90, step=0.01, key="dota_soft_over")
        soft_under = quote_columns[2].number_input("Odd Under Dota", min_value=1.01, value=1.90, step=0.01, key="dota_soft_under")
        submitted = st.form_submit_button("Calcular Pinnacle Sintética Dota 2", type="primary")
    if submitted:
        try:
            result = predict_dota_quote(
                state, feature_input,
                {"line": soft_line, "odds_over": soft_over, "odds_under": soft_under},
            )
        except (ValueError, KeyError) as error:
            st.error(str(error))
            return None
        st.session_state["dota_last_result"] = {
            "inputs": {
                "game": "Dota 2", "team_one": team_one, "team_two": team_two,
                "competition": competition, "map_number": int(map_number),
                "features": feature_input, "soft_line": float(soft_line),
                "soft_over": float(soft_over), "soft_under": float(soft_under),
            },
            "prediction": result,
        }
    current = st.session_state.get("dota_last_result")
    if not current:
        return None
    result = current["prediction"]
    st.subheader("Resultado · Dota 2 · Pinnacle Sintética")
    metrics = st.columns(4)
    metrics[0].metric("Linha final prevista", f"{result['line']:.1f}")
    metrics[1].metric("Odd justa Over", f"{result['fair_odds_over']:.2f}")
    metrics[2].metric("Odd justa Under", f"{result['fair_odds_under']:.2f}")
    metrics[3].metric("Confiança", "Modelo")
    interval = result["line_interval"]
    st.write(f"Intervalo da linha: {interval['lower']:.1f} a {interval['upper']:.1f}")
    if st.button("Registrar comparação manual Dota 2", key="dota_register_comparison"):
        _append_manual_comparison(current)
        st.success("Comparação manual Dota 2 registrada em arquivo append-only.")
    if result.get("ev_status") == "same_line":
        st.write(f"EV condicional na mesma linha: Over {result['ev_over']:+.1%}; Under {result['ev_under']:+.1%}")
    else:
        st.warning("EV não calculado: a linha da soft book não coincide com a linha sintética prevista.")
    st.info("Dota 2 · Pinnacle Sintética · comparação manual. Nenhuma aposta é executada automaticamente.")
    return current
