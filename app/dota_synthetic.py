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
AUTO_LEAGUE_ID = "__auto__"
AUTO_LEAGUE_NAME = "Automática · histórico global"
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


def build_dota_team_catalog(catalog: dict[str, Any]) -> list[dict[str, Any]]:
    teams_by_id: dict[str, dict[str, Any]] = {}
    for league in catalog.get("leagues", []):
        league_id = str(league["source_league_id"])
        competition = {
            "source_league_id": league_id,
            "league_name": str(league.get("league_name", league_id)),
            "tier": str(league.get("tier", "")),
        }
        for raw_team in league.get("teams", []):
            team_id = str(raw_team["team_id"])
            last_seen = raw_team.get("last_seen")
            row = teams_by_id.setdefault(
                team_id,
                {
                    "team_id": team_id,
                    "team_name": str(raw_team.get("team_name", team_id)),
                    "last_seen": last_seen,
                    "_competitions": {},
                },
            )
            row["_competitions"][league_id] = competition
            if last_seen and (
                not row.get("last_seen")
                or _parse_datetime(str(last_seen)) > _parse_datetime(str(row["last_seen"]))
            ):
                row["team_name"] = str(raw_team.get("team_name", team_id))
                row["last_seen"] = last_seen

    result = []
    for row in teams_by_id.values():
        competitions = sorted(
            row.pop("_competitions").values(),
            key=lambda item: (item["league_name"].casefold(), item["source_league_id"]),
        )
        result.append({
            **row,
            "competitions": competitions,
            "competition_count": len(competitions),
        })
    return sorted(result, key=lambda item: (item["team_name"].casefold(), item["team_id"]))


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
    league_id: str | None,
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

    scoped = [
        row for row in snapshots
        if league_id not in (None, AUTO_LEAGUE_ID) and row["source_league_id"] == league_id
    ]
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
    if league_id in (None, AUTO_LEAGUE_ID):
        source_scope = "global_team_history"
    elif scoped:
        source_scope = "selected_league_then_global_team_history"
    else:
        source_scope = "selected_league_unavailable_then_global_team_history"
    metadata = {
        "map_number": int(map_number),
        "feature_cutoff": planned_start.isoformat(),
        "team_one_snapshot_match_id": one_row["opendota_match_id"],
        "team_two_snapshot_match_id": two_row["opendota_match_id"],
        "team_one_feature_as_of": one_row["scheduled_start"],
        "team_two_feature_as_of": two_row["scheduled_start"],
        "source_scope": source_scope,
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


def build_dota_quotes(
    primary_quote: dict[str, Any],
    additional_quotes: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    quotes = [{
        "bookmaker": str(primary_quote["bookmaker"]),
        "line": float(primary_quote["line"]),
        "odds_over": float(primary_quote["odds_over"]),
        "odds_under": float(primary_quote["odds_under"]),
        "slot": 1,
    }]
    for quote in additional_quotes:
        if not quote.get("enabled", True):
            continue
        quotes.append({
            "bookmaker": str(quote["bookmaker"]),
            "line": float(quote["line"]),
            "odds_over": float(quote["odds_over"]),
            "odds_under": float(quote["odds_under"]),
            "slot": int(quote["slot"]),
        })
    return quotes


def _append_manual_comparison(payload: dict[str, Any]) -> None:
    record = {
        "game": "Dota 2",
        "bundle_id": payload["prediction"].get("model_id"),
        "recorded_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "inputs": payload["inputs"],
        "prediction": payload["prediction"],
        "predictions": payload.get("predictions", [payload["prediction"]]),
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
    league_by_id = {
        AUTO_LEAGUE_ID: {
            "source_league_id": AUTO_LEAGUE_ID,
            "league_name": AUTO_LEAGUE_NAME,
            "tier": "",
        },
        **{str(row["source_league_id"]): row for row in leagues},
    }
    league_ids = list(league_by_id)
    league_id = st.selectbox(
        "Liga sintética Dota 2",
        league_ids,
        format_func=lambda value: (
            AUTO_LEAGUE_NAME
            if value == AUTO_LEAGUE_ID
            else f"{league_by_id[value]['league_name']} · Tier {league_by_id[value]['tier']}"
        ),
        key="dota_league",
    )
    league = league_by_id[league_id]
    team_rows = build_dota_team_catalog(state["catalog"])
    team_by_id = {str(row["team_id"]): row for row in team_rows}
    team_ids = list(team_by_id)
    if len(team_ids) < 2:
        st.warning("O catálogo Dota não possui duas equipes com histórico point-in-time suficiente.")
        return None
    team_name_counts: dict[str, int] = {}
    for row in team_rows:
        team_name_counts[row["team_name"]] = team_name_counts.get(row["team_name"], 0) + 1
    team_labels = {
        team_id: (
            f"{row['team_name']} · {row['competition_count']} competições S/A"
            + (f" · ID {team_id}" if team_name_counts[row["team_name"]] > 1 else "")
        )
        for team_id, row in team_by_id.items()
    }
    selection_columns = st.columns(3)
    team_one_id = selection_columns[0].selectbox(
        "Equipe 1", team_ids,
        format_func=team_labels.get,
        key="dota_team_one",
    )
    team_two_ids = [value for value in team_ids if value != team_one_id]
    team_two_id = selection_columns[1].selectbox(
        "Equipe 2", team_two_ids,
        index=0,
        format_func=team_labels.get,
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
    additional_quotes: list[dict[str, Any]] = []
    for quote_number in (2, 3):
        enabled = st.checkbox(
            f"Adicionar cotação sintética {quote_number}",
            key=f"dota_enable_quote_{quote_number}",
        )
        if enabled:
            extra_columns = st.columns(4)
            extra_bookmaker = extra_columns[0].text_input(
                f"Casa soft sintética {quote_number}",
                placeholder="Ex.: Bet365",
                key=f"dota_bookmaker_{quote_number}",
            )
            extra_line = extra_columns[1].number_input(
                f"Linha soft sintética {quote_number}",
                min_value=0.5,
                value=48.5,
                step=0.5,
                key=f"dota_line_{quote_number}",
            )
            extra_over = extra_columns[2].number_input(
                f"Odd Over soft sintética {quote_number}",
                min_value=1.01,
                value=1.90,
                step=0.01,
                key=f"dota_over_{quote_number}",
            )
            extra_under = extra_columns[3].number_input(
                f"Odd Under soft sintética {quote_number}",
                min_value=1.01,
                value=1.90,
                step=0.01,
                key=f"dota_under_{quote_number}",
            )
            additional_quotes.append({
                "enabled": True,
                "bookmaker": extra_bookmaker,
                "line": extra_line,
                "odds_over": extra_over,
                "odds_under": extra_under,
                "slot": quote_number,
            })
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
        if not bookmaker.strip():
            st.error("Informe a casa soft antes de calcular.")
            return None
        if any(not quote["bookmaker"].strip() for quote in additional_quotes):
            st.error("Informe a casa de cada cotação sintética ativada.")
            return None
        quotes = build_dota_quotes(
            {
                "bookmaker": bookmaker.strip(),
                "line": soft_line,
                "odds_over": soft_over,
                "odds_under": soft_under,
            },
            [{**quote, "bookmaker": quote["bookmaker"].strip()} for quote in additional_quotes],
        )
        try:
            predictions = [
                predict_dota_quote(
                    state,
                    automatic_features,
                    {"line": quote["line"], "odds_over": quote["odds_over"], "odds_under": quote["odds_under"]},
                )
                for quote in quotes
            ]
        except (ValueError, KeyError) as error:
            st.error(str(error))
            return None
        result = predictions[0]
        st.session_state["dota_last_result"] = {
            "inputs": {
                "game": "Dota 2",
                "bookmaker": bookmaker,
                "league_id": league_id,
                "league_name": league["league_name"],
                "tier": league.get("tier") or None,
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
                "quotes": quotes,
            },
            "prediction": result,
            "predictions": predictions,
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
    quotes = current["inputs"].get("quotes", [{
        "bookmaker": current["inputs"].get("bookmaker", ""),
        "line": current["inputs"]["soft_line"],
        "odds_over": current["inputs"]["soft_over"],
        "odds_under": current["inputs"]["soft_under"],
        "slot": 1,
    }])
    predictions = current.get("predictions", [result])
    st.subheader("Confiômetro e valor por cotação soft")
    for quote, quote_result in zip(quotes, predictions):
        st.markdown(f"**Cotação {quote['slot']} · {quote['bookmaker']} · linha {quote['line']:.1f}**")
        quote_metrics = st.columns(4)
        quote_metrics[0].metric("Odd justa Over", f"{quote_result['fair_odds_over']:.2f}")
        quote_metrics[1].metric("EV Over", f"{quote_result['ev_over']:+.1%}" if quote_result.get("ev_over") is not None else "N/A")
        quote_metrics[2].metric("Odd justa Under", f"{quote_result['fair_odds_under']:.2f}")
        quote_metrics[3].metric("EV Under", f"{quote_result['ev_under']:+.1%}" if quote_result.get("ev_under") is not None else "N/A")
        if quote_result.get("ev_status") != "same_line":
            st.warning("EV não calculado: a linha da soft book não coincide com a linha sintética prevista.")
    if st.button("Registrar comparação manual Dota 2", key="dota_register_comparison"):
        _append_manual_comparison(current)
        st.success("Comparação manual Dota 2 registrada em arquivo append-only.")
    st.info("Dota 2 · Pinnacle Sintética · comparação manual. Nenhuma aposta é executada automaticamente.")
    return current
