from __future__ import annotations

import json
import math
from datetime import date, datetime, time, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import streamlit as st

from app.dota_inference import PROHIBITED_FEATURES, load_bundle, predict
from app.dota_team_identity import (
    build_operational_team_catalog,
    resolve_team_identity,
)
from app.synthetic_pinnacle import _direct_quote_metrics


DOTA_BUNDLE_PATH = Path("app_data/dota2_pinnacle_pre_draft_bundle.json")
DOTA_CATALOG_PATH = Path("app_data/dota_ui_catalog.json")
DOTA_IDENTITY_REGISTRY_PATH = Path("app_data/dota_team_identity_registry.json")
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
                    "history_map_count": 0,
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

    for raw_team in catalog.get("team_history", []):
        team_id = str(raw_team["team_id"])
        last_seen = raw_team.get("last_seen")
        row = teams_by_id.setdefault(
            team_id,
            {
                "team_id": team_id,
                "team_name": str(raw_team.get("team_name", team_id)),
                "last_seen": last_seen,
                "history_map_count": 0,
                "_competitions": {},
            },
        )
        row["history_map_count"] = max(
            int(row.get("history_map_count", 0) or 0),
            int(raw_team.get("map_count", 0) or 0),
        )
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
            "history_map_count": int(row.get("history_map_count", 0) or 0),
            "history_only": len(competitions) == 0,
        })
    return sorted(result, key=lambda item: (item["team_name"].casefold(), item["team_id"]))


def load_dota_state() -> dict[str, Any]:
    bundle = load_bundle(DOTA_BUNDLE_PATH)
    catalog = json.loads(DOTA_CATALOG_PATH.read_text(encoding="utf-8"))
    identity_registry = {}
    if DOTA_IDENTITY_REGISTRY_PATH.exists():
        identity_registry = json.loads(
            DOTA_IDENTITY_REGISTRY_PATH.read_text(encoding="utf-8")
        )
    if tuple(catalog.get("feature_names", ())) != FEATURE_NAMES:
        raise ValueError("Catálogo Dota incompatível com as oito features promovidas.")
    return {
        "bundle": bundle,
        "catalog": catalog,
        "identity_registry": identity_registry,
        "bundle_path": DOTA_BUNDLE_PATH,
        "catalog_path": DOTA_CATALOG_PATH,
        "identity_registry_path": DOTA_IDENTITY_REGISTRY_PATH,
    }


def build_dota_operational_catalog(state: dict[str, Any]) -> list[dict[str, Any]]:
    return build_operational_team_catalog(
        state.get("catalog", {}), state.get("identity_registry", {})
    )


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
    identity_metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    invalid = set(features).intersection(PROHIBITED_FEATURES)
    if invalid:
        raise ValueError(f"Inputs proibidos no contrato pré-draft: {sorted(invalid)}")
    bundle = state["bundle"]
    feature_names = set(bundle.get("feature_names", []))
    prediction = predict(bundle, {name: features.get(name) for name in feature_names})
    prediction["model_id"] = bundle.get("model_id")
    prediction["automatic_betting_approved"] = False
    identity_metadata = identity_metadata or {}
    identity_review_required = any(
        bool(row.get("manual_comparison_blocked"))
        for row in identity_metadata.values()
        if isinstance(row, dict)
    )
    prediction["identity_metadata"] = identity_metadata
    prediction["identity_review_required"] = identity_review_required
    prediction["confidence"] = "identity_review" if identity_review_required else "model_only"
    if soft_quote is None:
        return prediction
    line = float(soft_quote["line"])
    odds_over = float(soft_quote["odds_over"])
    odds_under = float(soft_quote["odds_under"])
    if not math.isclose(line % 1, 0.5, abs_tol=1e-12):
        raise ValueError("A linha Dota deve terminar em .5.")
    if odds_over <= 1.0 or odds_under <= 1.0:
        raise ValueError("As odds Dota devem ser maiores que 1.00.")
    market_model = bundle.get("market_model") or {}
    predicted_line_raw = float(prediction["line"])
    predicted_probability_over = min(
        max(float(prediction["probability_over"]), 1e-6),
        1.0 - 1e-6,
    )
    predicted_price_logit = math.log(
        predicted_probability_over / (1.0 - predicted_probability_over)
    )
    line_interval_half_width = float(
        market_model.get("line_interval_half_width", 2.0)
    )
    line_interval = market_model.get("line_model", {}).get(
        "residual_interval",
        {"lower": -line_interval_half_width, "upper": line_interval_half_width},
    )
    price_interval = market_model.get("price_model", {}).get(
        "residual_logit_interval",
        {"lower": -0.2, "upper": 0.2},
    )
    quote_bundle = {
        "market_probability_logit_slope_per_kill": float(
            market_model.get("market_probability_logit_slope_per_kill", 0.08)
        ),
        "line_model": {"residual_interval": line_interval},
        "price_model": {"residual_logit_interval": price_interval},
        "minimum_conservative_ev": float(
            market_model.get("minimum_conservative_ev", 0.05)
        ),
    }
    quote = _direct_quote_metrics(
        predicted_line_raw,
        predicted_price_logit,
        line,
        odds_over,
        odds_under,
        quote_bundle,
    )
    predicted_final_line = round(predicted_line_raw * 2.0) / 2.0
    predicted_hold = float(market_model.get("predicted_hold", 1.0))
    predicted_final_odds_over = 1.0 / (predicted_probability_over * predicted_hold)
    predicted_final_odds_under = 1.0 / ((1.0 - predicted_probability_over) * predicted_hold)
    signal = (
        bundle.get("status") == "approved_for_manual_soft_comparison"
        and quote["recommended_side"] is not None
        and not identity_review_required
    )
    prediction["soft_quote"] = {
        "line": line,
        "odds_over": odds_over,
        "odds_under": odds_under,
    }
    prediction.update(quote)
    prediction.update({
        "ev_status": "calculated",
        "model_id": bundle.get("model_id"),
        "model_status": bundle.get("status"),
        "forecast_target": (bundle.get("target_contract") or {}).get("target"),
        "predicted_final_line": predicted_final_line,
        "predicted_final_line_raw": predicted_line_raw,
        "predicted_final_line_low": predicted_line_raw + float(line_interval["lower"]),
        "predicted_final_line_high": predicted_line_raw + float(line_interval["upper"]),
        "predicted_final_probability_over": predicted_probability_over,
        "predicted_final_probability_under": 1.0 - predicted_probability_over,
        "predicted_final_odds_over": predicted_final_odds_over,
        "predicted_final_odds_under": predicted_final_odds_under,
        "predicted_final_hold": predicted_hold,
        "recommended_side": quote["recommended_side"] if signal else None,
        "action": "manual_review" if signal else "abstain",
        "stake": 0.0,
        "automatic_betting_approved": False,
        "blocked_reasons": (
            []
            if signal
            else [
                *(["team_identity_review"] if identity_review_required else []),
                "EV conservador abaixo do mínimo ou modelo em shadow.",
            ]
        ),
    })
    if identity_review_required:
        prediction["confidence"] = "identity_review"
    prediction["line_interval"] = {
        "lower": prediction["predicted_final_line_low"],
        "upper": prediction["predicted_final_line_high"],
    }
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
    timing_columns = st.columns(2)
    planned_date = timing_columns[0].date_input(
        "Data planejada sintética",
        value=datetime.now(ZoneInfo("America/Sao_Paulo")).date(),
        key="dota_planned_date",
    )
    planned_time = timing_columns[1].selectbox(
        "Horário planejado sintético",
        _time_options(),
        index=0,
        format_func=lambda value: value.strftime("%H:%M"),
        key="dota_planned_time",
    )
    planned_start = datetime.combine(
        planned_date, planned_time, tzinfo=ZoneInfo("America/Sao_Paulo")
    ).astimezone(timezone.utc)

    operational_rows = build_dota_operational_catalog(state)
    operational_by_name = {
        row["canonical_team_name"]: row for row in operational_rows
    }
    team_names = list(operational_by_name)
    if len(team_names) < 2:
        st.warning("O catálogo Dota não possui duas equipes operacionais disponíveis.")
        return None

    def operational_label(name: str) -> str:
        row = operational_by_name[name]
        latest = row.get("latest_identity") or {}
        status = latest.get("roster_status", "unknown")
        current_members = latest.get("current_membership_count")
        roster_text = (
            f"elenco observado {current_members}/5"
            if current_members is not None
            else "elenco sem evidência"
        )
        return (
            f"{name} · ID automático {latest.get('opendota_team_id', 'N/D')} · "
            f"{status} · {roster_text}"
        )

    selection_columns = st.columns(3)
    team_one_name = selection_columns[0].selectbox(
        "Equipe 1", team_names,
        format_func=operational_label,
        key="dota_team_one",
    )
    team_two_names = [value for value in team_names if value != team_one_name]
    team_two_name = selection_columns[1].selectbox(
        "Equipe 2", team_two_names,
        index=0,
        format_func=operational_label,
        key="dota_team_two",
    )
    map_number = selection_columns[2].number_input(
        "Mapa da série", min_value=1, max_value=7, value=1, step=1, key="dota_map_number"
    )

    selected_team_rows = {
        "team_one": operational_by_name[team_one_name],
        "team_two": operational_by_name[team_two_name],
    }
    with st.expander("Identidade histórica avançada", expanded=False):
        st.caption(
            "A seleção automática usa a identidade mais recente anterior ao horário planejado. "
            "Use o override somente quando houver evidência externa do elenco/evento."
        )
        override_columns = st.columns(2)
        overrides: dict[str, str] = {}
        for label, column in (("team_one", override_columns[0]), ("team_two", override_columns[1])):
            row = selected_team_rows[label]
            identities = row.get("historical_identities", [])
            options = ["__auto__"] + [str(item["opendota_team_id"]) for item in identities]
            overrides[label] = column.selectbox(
                f"ID histórico {1 if label == 'team_one' else 2}",
                options,
                format_func=lambda value, row=row: (
                    "Automático · por data/evento"
                    if value == "__auto__"
                    else next(
                        (
                            f"{item.get('team_name', row['canonical_team_name'])} · ID {value} · "
                            f"último jogo {item.get('last_seen', 'N/D')}"
                            for item in row.get("historical_identities", [])
                            if str(item["opendota_team_id"]) == str(value)
                        ),
                        f"ID {value}",
                    )
                ),
                key=f"dota_identity_override_{label}",
            )

    identity_metadata: dict[str, Any] = {}
    resolved_ids: dict[str, str | None] = {}
    for label, row in selected_team_rows.items():
        override = overrides.get(label, "__auto__")
        resolved = resolve_team_identity(
            row.get("historical_identities", []),
            planned_start.isoformat(),
            approved_event_team_id=None if override == "__auto__" else override,
        )
        if override != "__auto__" and resolved.get("opendota_team_id") == override:
            resolved["resolution_method"] = "manual_historical_override"
        resolved["canonical_team_name"] = row["canonical_team_name"]
        identity_metadata[label] = resolved
        resolved_ids[label] = resolved.get("opendota_team_id")

    for label, resolved in identity_metadata.items():
        readable_label = "Equipe 1" if label == "team_one" else "Equipe 2"
        observed_members = [
            str(member.get("name") or member.get("account_id"))
            for member in (resolved.get("selected_identity", {}).get("last_observed_roster_members", []) or [])
        ]
        if resolved.get("manual_comparison_blocked"):
            st.warning(
                f"{readable_label}: identidade {resolved.get('identity_status', 'desconhecida')} "
                f"ou elenco não confirmado. A simulação ficará bloqueada para comparação manual."
            )
        else:
            st.caption(
                f"{readable_label}: ID OpenDota {resolved.get('opendota_team_id')} · "
                f"evidência {resolved.get('identity_status', 'desconhecida')}."
            )
        if observed_members:
            st.caption(f"Membros atuais observados no OpenDota: {', '.join(observed_members)}.")

    team_one_id = resolved_ids["team_one"]
    team_two_id = resolved_ids["team_two"]
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
    submitted = st.button("Calcular Pinnacle sintética", type="primary", key="dota_calculate")

    automatic_features, feature_metadata, feature_error = _resolve_automatic_features(
        state["catalog"], league_id, str(team_one_id), str(team_two_id), int(map_number), planned_start
    )
    feature_metadata["team_one_identity"] = identity_metadata["team_one"]
    feature_metadata["team_two_identity"] = identity_metadata["team_two"]
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
                    identity_metadata=identity_metadata,
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
                "team_one": team_one_name,
                "team_two": team_two_name,
                "team_one_id": str(team_one_id),
                "team_two_id": str(team_two_id),
                "map_number": int(map_number),
                "planned_start": planned_start.isoformat(),
                "features": automatic_features,
                "feature_metadata": feature_metadata,
                "identity_metadata": identity_metadata,
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
    if result.get("identity_review_required"):
        st.error(
            "Identidade ou elenco não confiável para este momento. "
            "A linha foi calculada apenas para pesquisa; a comparação manual está bloqueada."
        )
    metrics = st.columns(4)
    metrics[0].metric(
        "Linha Pinnacle final esperada",
        f"{result['predicted_final_line']:.1f}",
    )
    metrics[1].metric(
        "Intervalo conservador",
        f"{result['predicted_final_line_low']:.1f} a "
        f"{result['predicted_final_line_high']:.1f}",
    )
    metrics[2].metric(
        "EV conservador Over",
        f"{result['conservative_ev_over']:+.1%}",
    )
    metrics[3].metric(
        "EV conservador Under",
        f"{result['conservative_ev_under']:+.1%}",
    )
    probability_columns = st.columns(4)
    probability_columns[0].metric(
        "Probabilidade Over",
        f"{result['probability_over']:.1%}",
    )
    probability_columns[1].metric(
        "Odd justa Over",
        f"{result['fair_odds_over']:.2f}",
    )
    probability_columns[2].metric(
        "Probabilidade Under",
        f"{result['probability_under']:.1%}",
    )
    probability_columns[3].metric(
        "Odd justa Under",
        f"{result['fair_odds_under']:.2f}",
    )
    final_price_columns = st.columns(3)
    final_price_columns[0].metric(
        "Odd Pinnacle final Over prevista",
        f"{result['predicted_final_odds_over']:.2f}",
    )
    final_price_columns[1].metric(
        "Odd Pinnacle final Under prevista",
        f"{result['predicted_final_odds_under']:.2f}",
    )
    final_price_columns[2].metric(
        "Probabilidade no-vig Over final",
        f"{result['predicted_final_probability_over']:.1%}",
    )
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
        quote_metrics = st.columns(6)
        quote_metrics[0].metric(
            "Odd justa Over",
            f"{quote_result['fair_odds_over']:.2f}",
        )
        quote_metrics[1].metric(
            "EV Over",
            f"{quote_result['ev_over']:+.1%}",
        )
        quote_metrics[2].metric(
            "EV conservador Over",
            f"{quote_result['conservative_ev_over']:+.1%}",
        )
        quote_metrics[3].metric(
            "Odd justa Under",
            f"{quote_result['fair_odds_under']:.2f}",
        )
        quote_metrics[4].metric(
            "EV Under",
            f"{quote_result['ev_under']:+.1%}",
        )
        quote_metrics[5].metric(
            "EV conservador Under",
            f"{quote_result['conservative_ev_under']:+.1%}",
        )
        st.info(
            "Confiômetro: "
            f"{str(quote_result.get('confidence', 'indisponível')).title()}."
        )
    if result["action"] == "manual_review":
        st.warning(
            f"Revisão manual: possível {result['recommended_side'].title()}. "
            "Stake automática permanece bloqueada."
        )
    else:
        st.info("EV conservador insuficiente. Não apostar.")
    if st.button("Registrar comparação manual Dota 2", key="dota_register_comparison"):
        _append_manual_comparison(current)
        st.success("Comparação manual Dota 2 registrada em arquivo append-only.")
    st.info("Dota 2 · Pinnacle Sintética · comparação manual. Nenhuma aposta é executada automaticamente.")
    return current
