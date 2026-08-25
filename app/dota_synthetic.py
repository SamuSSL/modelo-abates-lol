from __future__ import annotations

import json
import math
from datetime import date, datetime, time, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import streamlit as st

from app.dota_inference import PROHIBITED_FEATURES, load_bundle, predict


DOTA_BUNDLE_PATH = Path("app_data/dota2_pinnacle_pre_draft_bundle.json")
DOTA_CATALOG_PATH = Path("app_data/dota_ui_catalog.json")
DOTA_DECISIONS_PATH = Path("app_data/dota_manual_comparisons.jsonl")
FEATURE_NAMES = (
    "team_one_kills_for",
    "team_one_kills_against",
    "team_two_kills_for",
    "team_two_kills_against",
    "team_one_kills_for_recency_15d",
    "team_one_kills_against_recency_15d",
    "team_two_kills_for_recency_15d",
    "team_two_kills_against_recency_15d",
)
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


def _parse_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed


def load_dota_state() -> dict[str, Any]:
    bundle = load_bundle(DOTA_BUNDLE_PATH)
    catalog = json.loads(DOTA_CATALOG_PATH.read_text(encoding="utf-8"))
    if tuple(catalog.get("feature_names", ())) != FEATURE_NAMES:
        raise ValueError("Catálogo Dota incompatível com as oito features promovidas.")
    return {"bundle": bundle, "catalog": catalog, "bundle_path": DOTA_BUNDLE_PATH, "catalog_path": DOTA_CATALOG_PATH}


def _extract_team_features(row: dict[str, Any], side: str) -> dict[str, float]:
    prefix = "team_one" if side == "one" else "team_two"
    return {
        "kills_for": float(row["features"][f"{prefix}_kills_for"]),
        "kills_against": float(row["features"][f"{prefix}_kills_against"]),
        "kills_for_recency_15d": float(row["features"][f"{prefix}_kills_for_recency_15d"]),
        "kills_against_recency_15d": float(row["features"][f"{prefix}_kills_against_recency_15d"]),
    }


def _resolve_automatic_features(
    catalog: dict[str, Any],
    league_id: str,
    team_one_id: str,
    team_two_id: str,
    map_number: int,
    planned_start: datetime,
) -> tuple[dict[str, float] | None, dict[str, Any], str | None]:
    snapshots = [
        row for row in catalog.get("snapshots", [])
        if _parse_datetime(row["scheduled_start"]) < planned_start
    ]
    if not snapshots:
        return None, {}, "Não há snapshot histórico anterior ao início planejado."

    scoped = [row for row in snapshots if row["source_league_id"] == league_id]
    sources = (scoped, snapshots) if scoped else (snapshots,)
    selected_rows: dict[str, tuple[dict[str, Any], str]] = {}
    for candidates in sources:
        for team_id in (team_one_id, team_two_id):
            if team_id in selected_rows:
                continue
            team_rows = [
                row for row in candidates
                if row["team_one_id"] == team_id or row["team_two_id"] == team_id
            ]
            if not team_rows:
                continue
            row = max(team_rows, key=lambda item: _parse_datetime(item["scheduled_start"]))
            side = "one" if row["team_one_id"] == team_id else "two"
            selected_rows[team_id] = (row, side)
    if team_one_id not in selected_rows or team_two_id not in selected_rows:
        return None, {}, "Não existe histórico point-in-time suficiente para as duas equipes selecionadas."

    one_row, one_side = selected_rows[team_one_id]
    two_row, two_side = selected_rows[team_two_id]
    one = _extract_team_features(one_row, one_side)
    two = _extract_team_features(two_row, two_side)
    features = {
        "team_one_kills_for": one["kills_for"],
        "team_one_kills_against": one["kills_against"],
        "team_two_kills_for": two["kills_for"],
        "team_two_kills_against": two["kills_against"],
        "team_one_kills_for_recency_15d": one["kills_for_recency_15d"],
        "team_one_kills_against_recency_15d": one["kills_against_recency_15d"],
        "team_two_kills_for_recency_15d": two["kills_for_recency_15d"],
        "team_two_kills_against_recency_15d": two["kills_against_recency_15d"],
    }
    metadata = {
        "map_number": int(map_number),
        "feature_cutoff": planned_start.isoformat(),
        "team_one_snapshot_match_id": one_row["opendota_match_id"],
        "team_two_snapshot_match_id": two_row["opendota_match_id"],
        "team_one_feature_as_of": one_row["scheduled_start"],
        "team_two_feature_as_of": two_row["scheduled_start"],
        "source_scope": "selected_league_then_global_team_history",
    }
    return features, metadata, None


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
    prediction["soft_quote"] = {"line": line, "odds_over": odds_over, "odds_under": odds_under}
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


def _time_options() -> list[time]:
    return [time(hour, minute) for hour in range(24) for minute in (0, 15, 30, 45)]


def render_dota_tab(state: dict[str, Any]) -> dict[str, Any] | None:
    st.header("Dota 2 · Pinnacle Sintética")
    st.caption("Linha principal e odds finais estimadas antes da abertura, com features históricas preenchidas automaticamente.")
    st.warning("Dota 2 · pré-draft · side-agnostic · sem heróis/draft/eventos · sem aposta automática.")
    leagues = state["catalog"].get("leagues", [])
    if not leagues:
        st.error("Catálogo Dota sem ligas S/A disponíveis.")
        return None
    league_by_id = {str(row["source_league_id"]): row for row in leagues}
    league_ids = list(league_by_id)
    league_id = st.selectbox(
        "Liga sintética Dota 2",
        league_ids,
        format_func=lambda value: f"{league_by_id[value]['league_name']} · Tier {league_by_id[value]['tier']}",
        key="dota_league",
    )
    league = league_by_id[league_id]
    team_rows = league.get("teams", [])
    team_by_id = {str(row["team_id"]): row for row in team_rows}
    team_ids = list(team_by_id)
    if len(team_ids) < 2:
        st.warning("Esta liga não possui duas equipes com histórico point-in-time suficiente.")
        return None
    selection_columns = st.columns(3)
    team_one_id = selection_columns[0].selectbox(
        "Equipe 1", team_ids,
        format_func=lambda value: team_by_id[value]["team_name"],
        key="dota_team_one",
    )
    team_two_ids = [value for value in team_ids if value != team_one_id]
    team_two_id = selection_columns[1].selectbox(
        "Equipe 2", team_two_ids,
        index=0,
        format_func=lambda value: team_by_id[value]["team_name"],
        key="dota_team_two",
    )
    map_number = selection_columns[2].number_input(
        "Mapa da série", min_value=1, max_value=7, value=1, step=1, key="dota_map_number"
    )
    quote_columns = st.columns(4)
    bookmaker = quote_columns[0].text_input("Casa soft sintética", placeholder="Ex.: Bet365", key="dota_bookmaker")
    soft_line = quote_columns[1].number_input("Linha soft sintética", min_value=0.5, value=48.5, step=0.5, key="dota_soft_line")
    soft_over = quote_columns[2].number_input("Odd Over soft sintética", min_value=1.01, value=1.90, step=0.01, key="dota_soft_over")
    soft_under = quote_columns[3].number_input("Odd Under soft sintética", min_value=1.01, value=1.90, step=0.01, key="dota_soft_under")
    timing_columns = st.columns(2)
    planned_date = timing_columns[0].date_input(
        "Data planejada sintética", value=datetime.now(ZoneInfo("America/Sao_Paulo")).date(), key="dota_planned_date"
    )
    planned_time = timing_columns[1].selectbox(
        "Horário planejado sintético", _time_options(),
        index=0,
        format_func=lambda value: value.strftime("%H:%M"),
        key="dota_planned_time",
    )
    submitted = st.button("Calcular Pinnacle sintética", type="primary", key="dota_calculate")

    planned_start = datetime.combine(planned_date, planned_time, tzinfo=ZoneInfo("America/Sao_Paulo")).astimezone(timezone.utc)
    automatic_features, feature_metadata, feature_error = _resolve_automatic_features(
        state["catalog"], league_id, str(team_one_id), str(team_two_id), int(map_number), planned_start
    )
    if automatic_features is not None:
        st.caption(
            "Features point-in-time preenchidas automaticamente. "
            f"Snapshots: {feature_metadata['team_one_feature_as_of']} e {feature_metadata['team_two_feature_as_of']}."
        )
        with st.expander("Ver features históricas automáticas"):
            st.dataframe(
                {"feature": [FEATURE_LABELS[name] for name in FEATURE_NAMES], "valor": [automatic_features[name] for name in FEATURE_NAMES]},
                hide_index=True,
                width="stretch",
            )
    else:
        st.warning(feature_error or "Não foi possível resolver as features históricas automaticamente.")

    if submitted:
        if automatic_features is None:
            st.error(feature_error or "A previsão foi bloqueada por falta de histórico point-in-time.")
            return None
        try:
            result = predict_dota_quote(
                state, automatic_features,
                {"line": soft_line, "odds_over": soft_over, "odds_under": soft_under},
            )
        except (ValueError, KeyError) as error:
            st.error(str(error))
            return None
        st.session_state["dota_last_result"] = {
            "inputs": {
                "game": "Dota 2",
                "bookmaker": bookmaker,
                "league_id": league_id,
                "league_name": league["league_name"],
                "tier": league["tier"],
                "team_one": team_by_id[str(team_one_id)]["team_name"],
                "team_two": team_by_id[str(team_two_id)]["team_name"],
                "team_one_id": str(team_one_id),
                "team_two_id": str(team_two_id),
                "map_number": int(map_number),
                "planned_start": planned_start.isoformat(),
                "features": automatic_features,
                "feature_metadata": feature_metadata,
                "soft_line": float(soft_line),
                "soft_over": float(soft_over),
                "soft_under": float(soft_under),
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
