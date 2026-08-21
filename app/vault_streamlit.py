from __future__ import annotations

import os
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import pandas as pd
import streamlit as st
from streamlit.errors import StreamlitSecretNotFoundError

from app.lolkills_inference import load_bundle, predict
from app.persistence import (
    load_bet_history,
    load_soft_quote_observations,
    save_bet_decision,
    save_pinnacle_forecast,
    save_prediction,
    save_quote_outcome,
    save_shadow_predictions,
    save_soft_quote_observation,
)
from app.prematch_forecast import assess_soft_model_readiness
from app.synthetic_pinnacle import (
    load_synthetic_pinnacle_bundle,
    predict_synthetic_pinnacle,
    predict_synthetic_pinnacle_quotes,
)
from app.shadow_models import (
    build_operational_prediction,
    build_shadow_predictions,
)
from app.tracking import load_tracking_data, render_tracking_page
from app.ui_options import team_label, team_options


BUNDLE_PATH = Path("app_data/model_bundle.json")
ROSTER_CATALOG_PATH = Path("app_data/roster_catalog.json")
TRACKING_PATH = Path("app_data/time_series_tracking.csv.gz")
SYNTHETIC_PINNACLE_PATH = Path("app_data/synthetic_pinnacle_bundle.json")
UI_RELEASE = "synthetic-pinnacle-direct-v7-2026-08-05"
STRUCTURAL_REFERENCE_INTERFACE = "predraft-ev-v2-2026-08-04"


def _probability_over_at_line(pmf: list[float], line: float) -> float:
    return float(sum(pmf[int(line // 1) + 1:]))


def _result_at_soft_quote(
    result: dict[str, Any],
    line: float,
    odds_over: float,
    odds_under: float,
) -> dict[str, Any]:
    adjusted = dict(result)
    if result.get("status") != "ok" or not result.get("pmf"):
        return adjusted
    probability_over = _probability_over_at_line(result["pmf"], line)
    probability_under = 1 - probability_over
    adjusted.update({
        "probability_over": probability_over,
        "probability_under": probability_under,
        "fair_odds_over": 1 / probability_over,
        "fair_odds_under": 1 / probability_under,
        "ev_over": probability_over * odds_over - 1,
        "ev_under": probability_under * odds_under - 1,
    })
    return adjusted


@st.cache_resource
def _load_active_bundle(bundle_mtime_ns: int):
    return load_bundle(BUNDLE_PATH)


@st.cache_resource
def _load_roster_catalog(catalog_mtime_ns: int):
    with ROSTER_CATALOG_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _database_url() -> str | None:
    database_url = os.getenv("DATABASE_URL")
    try:
        if "database" in st.secrets:
            database_url = st.secrets["database"].get("url")
    except StreamlitSecretNotFoundError:
        pass
    return database_url


def _apply_theme() -> None:
    st.markdown(
        """
        <style>
          :root {
            --vault-bg: #07050b;
            --vault-surface: #100b17;
            --vault-surface-2: #171020;
            --vault-border: #34264a;
            --vault-purple: #8b5cf6;
            --vault-purple-bright: #a78bfa;
            --vault-purple-deep: #5b21b6;
            --vault-text: #f7f4ff;
            --vault-muted: #b7acc8;
            --vault-success: #5ee6a8;
          }
          .stApp {
            background:
              radial-gradient(circle at 82% 2%, rgba(91, 33, 182, .22), transparent 30rem),
              var(--vault-bg);
            color: var(--vault-text);
          }
          .block-container {
            max-width: 1160px;
            padding-top: 1.5rem;
            padding-bottom: 3rem;
          }
          .vault-hero {
            border: 1px solid var(--vault-border);
            border-radius: 20px;
            padding: 1.45rem 1.6rem;
            background: linear-gradient(145deg, rgba(23, 16, 32, .96), rgba(10, 7, 15, .96));
            box-shadow: 0 20px 70px rgba(0, 0, 0, .34);
            margin-bottom: 1.1rem;
          }
          .vault-brand {
            color: var(--vault-purple-bright);
            font-size: .76rem;
            font-weight: 800;
            letter-spacing: .2em;
            text-transform: uppercase;
            margin-bottom: .5rem;
          }
          .vault-title {
            color: var(--vault-text);
            font-size: clamp(1.8rem, 4vw, 3rem);
            font-weight: 780;
            letter-spacing: -.04em;
            line-height: 1.06;
            margin: 0;
          }
          .vault-title .vault-company {
            display: block;
            color: var(--vault-purple-bright);
            font-size: .76rem;
            font-weight: 800;
            letter-spacing: .2em;
            line-height: 1.2;
            text-transform: uppercase;
            margin-bottom: .7rem;
          }
          .vault-subtitle {
            color: var(--vault-muted);
            line-height: 1.55;
            margin: .65rem 0 0;
            max-width: 760px;
          }
          .vault-model {
            display: inline-flex;
            align-items: center;
            min-height: 32px;
            margin-top: 1rem;
            padding: .25rem .75rem;
            border: 1px solid rgba(167, 139, 250, .42);
            border-radius: 999px;
            color: #ddd2ff;
            background: rgba(91, 33, 182, .16);
            font-size: .82rem;
            font-weight: 650;
          }
          [data-testid="stForm"],
          [data-testid="stVerticalBlockBorderWrapper"] {
            background: rgba(16, 11, 23, .82);
            border-color: var(--vault-border);
            border-radius: 16px;
          }
          [data-testid="stMetric"] {
            background: var(--vault-surface-2);
            border: 1px solid var(--vault-border);
            border-radius: 14px;
            padding: .9rem 1rem;
          }
          [data-testid="stMetricValue"] {
            color: var(--vault-text);
          }
          [data-baseweb="input"] > div,
          [data-baseweb="select"] > div {
            background: var(--vault-surface-2);
            border-color: var(--vault-border);
            min-height: 44px;
          }
          .stButton button,
          [data-testid="stFormSubmitButton"] button,
          .stDownloadButton button {
            min-height: 44px;
            border-radius: 10px;
            border-color: var(--vault-border);
            font-weight: 700;
          }
          .stButton button[kind="primary"] {
            background: var(--vault-purple-deep);
            border-color: var(--vault-purple);
            color: #ffffff;
          }
          .stButton button[kind="primary"]:hover {
            background: var(--vault-purple);
            border-color: var(--vault-purple-bright);
          }
          button:focus-visible,
          input:focus-visible,
          [role="combobox"]:focus-visible {
            outline: 3px solid rgba(167, 139, 250, .72) !important;
            outline-offset: 2px;
          }
          [data-testid="stDataFrame"] {
            border: 1px solid var(--vault-border);
            border-radius: 14px;
            overflow: hidden;
          }
          [data-testid="stRadio"] [role="radiogroup"] {
            gap: .35rem;
            padding: .28rem;
            border: 1px solid var(--vault-border);
            border-radius: 12px;
            background: var(--vault-surface);
          }
          .model-note {
            color: var(--vault-muted);
            line-height: 1.55;
            margin-top: 1.5rem;
          }
          @media (max-width: 700px) {
            .block-container {
              padding: 2.5rem .75rem 2rem !important;
            }
            .vault-hero {
              padding: 1.15rem;
              border-radius: 16px;
            }
          }
          @media (prefers-reduced-motion: reduce) {
            *, *::before, *::after {
              scroll-behavior: auto !important;
              transition-duration: .01ms !important;
              animation-duration: .01ms !important;
            }
          }
        </style>
        """,
        unsafe_allow_html=True,
    )


def _render_hero(bundle: dict | None = None) -> None:
    model_label = f"Vault Corp · Pinnacle sintética pré-abertura · Interface {UI_RELEASE}"
    st.markdown(
        f"""
        <section class="vault-hero">
          <h1 class="vault-title">LoL Kills Intelligence</h1>
          <p class="vault-subtitle">
            Linha principal e odds finais estimadas antes da abertura,
            para comparação manual com cotações disponíveis.
          </p>
          <div class="vault-model">{model_label}</div>
        </section>
        """,
        unsafe_allow_html=True,
    )


def _render_bet_history(database_url: str | None) -> None:
    st.title("Apostas registradas")
    st.write(
        "Cada linha reúne a partida, a decisão, o preço disponível e a "
        "previsão completa que existia no momento da aposta."
    )
    try:
        history = load_bet_history(database_url)
    except Exception as error:
        st.error(f"Não foi possível carregar o histórico: {error}")
        return
    if history.empty:
        st.info("Nenhuma aposta Over ou Under foi registrada.")
        return

    total_stake = float(history["stake"].fillna(0).sum())
    average_ev = history["expected_value"].dropna()
    metric_columns = st.columns(3)
    metric_columns[0].metric("Apostas", len(history))
    metric_columns[1].metric("Stake registrada", f"{total_stake:.0f} un.")
    metric_columns[2].metric(
        "EV médio no registro",
        f"{average_ev.mean():.1%}" if not average_ev.empty else "Sem dado",
    )

    display = history.copy()
    display["partida"] = (
        display["blue_team"] + " x " + display["red_team"]
    )
    display["lado"] = display["decision"].map(
        {"over": "Over", "under": "Under"}
    )
    display["probabilidade_modelo"] = display["chosen_probability"].map(
        lambda value: f"{value:.1%}" if pd.notna(value) else ""
    )
    display["ev_registro"] = display["expected_value"].map(
        lambda value: f"{value:.1%}" if pd.notna(value) else ""
    )
    display["referencia"] = display["prediction_source"].map(
        {
            "pinnacle_postdraft": "Pinnacle pós-draft",
            "directed_moneyline_fallback": "Modelo dirigido (fallback)",
            "structural_legacy": "Modelo estrutural",
        }
    ).fillna(display["prediction_source"])
    display["confiometro"] = display["agreement_message"].fillna(
        "Sem registro"
    )
    display_table = display.loc[
        :,
        [
            "bet_created_at",
            "planned_at",
            "league",
            "partida",
            "map_number",
            "lado",
            "line",
            "offered_odds",
            "stake",
            "referencia",
            "confiometro",
            "moneyline_blue_odds",
            "moneyline_red_odds",
            "probabilidade_modelo",
            "chosen_fair_odds",
            "ev_registro",
            "predicted_mean",
            "predicted_duration_mean",
            "pace",
            "model_version",
            "event_id",
        ],
    ].rename(
        columns={
            "bet_created_at": "Registro",
            "planned_at": "Início previsto",
            "league": "Liga",
            "partida": "Partida",
            "map_number": "Mapa",
            "lado": "Aposta",
            "line": "Linha",
            "offered_odds": "Odd",
            "stake": "Stake",
            "referencia": "Referência ativa",
            "confiometro": "Confiômetro",
            "moneyline_blue_odds": "ML azul",
            "moneyline_red_odds": "ML vermelha",
            "probabilidade_modelo": "Prob. modelo",
            "chosen_fair_odds": "Odd justa",
            "ev_registro": "EV",
            "predicted_mean": "Média prevista",
            "predicted_duration_mean": "Duração prevista",
            "pace": "Pace",
            "model_version": "Modelo",
            "event_id": "Evento",
        }
    )
    st.dataframe(
        display_table,
        hide_index=True,
        width="stretch",
    )
    st.download_button(
        "Baixar histórico completo em CSV",
        data=history.to_csv(index=False).encode("utf-8-sig"),
        file_name="vault-corp-apostas.csv",
        mime="text/csv",
        width="stretch",
    )
    st.caption(
        "O arquivo inclui odds dos dois lados, probabilidades, odds justas, "
        "moneyline, referência ativa, confiômetro, EVs de cada modelo, "
        "duração, intervalo preditivo, pace, cutoff e identificadores."
    )


def _render_prediction(bundle: dict, database_url: str | None) -> None:
    st.title("Total de kills por mapa")
    st.write(
        "Modelo experimental dirigido por equipe. Ele combina ratings de "
        "ataque e concessão, ritmo, duração esperada e a moneyline sem vig "
        "do mapa. Draft e campeões não entram nesta versão."
    )

    with st.container(border=True):
        st.subheader("Partida")
        league_options = bundle["model"]["league_levels"]
        league_team_counts = {
            league_name: len(team_options(bundle, league_name))
            for league_name in league_options
        }
        default_league_index = next(
            (
                index
                for index, league_name in enumerate(league_options)
                if league_team_counts[league_name] >= 2
            ),
            0,
        )
        match_columns = st.columns(4)
        league = match_columns[0].selectbox(
            "Liga",
            league_options,
            index=default_league_index,
        )
        planned_date = match_columns[1].date_input("Data prevista")
        planned_time = match_columns[2].time_input(
            "Horário de Brasília",
            help="O horário é convertido para UTC antes de salvar.",
        )
        map_number = match_columns[3].number_input(
            "Número do mapa",
            min_value=1,
            max_value=7,
            value=1,
            step=1,
        )

        available_teams = team_options(bundle, league)
        team_keys = [row["key"] for row in available_teams]
        team_by_key = {row["key"]: row for row in available_teams}
        team_limit = float(bundle["sample_limits"]["team_effective_games"])
        if len(team_keys) < 2:
            st.error("A liga não possui duas equipes no snapshot atual.")
            st.stop()
        team_columns = st.columns(2)
        selected_team_records = {}
        for side, label, column in (
            ("blue", "Equipe azul", team_columns[0]),
            ("red", "Equipe vermelha", team_columns[1]),
        ):
            with column:
                selected_team_key = st.selectbox(
                    label,
                    team_keys,
                    index=0 if side == "blue" else 1,
                    format_func=lambda key: team_label(
                        team_by_key[key],
                        team_limit,
                    ),
                    key=f"{side}_team",
                )
                selected_team_records[side] = team_by_key[selected_team_key]
                if (
                    selected_team_records[side]["effective_team_games"]
                    < team_limit
                ):
                    st.warning(
                        "Equipe abaixo do limite mínimo de amostra. "
                        "A previsão será bloqueada."
                    )

        st.subheader("Moneyline Pinnacle do mapa")
        moneyline_columns = st.columns(2)
        moneyline_blue_odds = moneyline_columns[0].number_input(
            "Odd ML equipe azul",
            min_value=0.0,
            value=0.0,
            step=0.01,
            help=(
                "Use a última odd Pinnacle disponível entre 15 e "
                "30 minutos antes do mapa."
            ),
        )
        moneyline_red_odds = moneyline_columns[1].number_input(
            "Odd ML equipe vermelha",
            min_value=0.0,
            value=0.0,
            step=0.01,
            help=(
                "Informe a odd do mesmo snapshot usado para a equipe azul."
            ),
        )

        st.subheader("Linha e odds de total de kills")
        market_columns = st.columns(3)
        line = market_columns[0].number_input(
            "Linha de kills",
            min_value=0.5,
            value=24.5,
            step=1.0,
            help="Somente linhas terminadas em .5.",
        )
        odds_over = market_columns[1].number_input(
            "Odd Over, opcional",
            min_value=0.0,
            value=0.0,
            step=0.01,
        )
        odds_under = market_columns[2].number_input(
            "Odd Under, opcional",
            min_value=0.0,
            value=0.0,
            step=0.01,
        )
        submitted = st.button(
            "Calcular previsão",
            type="primary",
            width="stretch",
        )

    if submitted:
        planned_local = datetime.combine(
            planned_date,
            planned_time,
            tzinfo=ZoneInfo("America/Sao_Paulo"),
        )
        request = {
            "league": league,
            "planned_at": planned_local.astimezone(timezone.utc).isoformat(),
            "map_number": int(map_number),
            "line": float(line),
            "odds_over": float(odds_over) if odds_over > 0 else None,
            "odds_under": float(odds_under) if odds_under > 0 else None,
            "moneyline_blue_odds": (
                float(moneyline_blue_odds)
                if moneyline_blue_odds > 0
                else None
            ),
            "moneyline_red_odds": (
                float(moneyline_red_odds)
                if moneyline_red_odds > 0
                else None
            ),
            "blue": {
                "team_name": selected_team_records["blue"]["team_name"],
                "team_id": selected_team_records["blue"].get("team_id"),
            },
            "red": {
                "team_name": selected_team_records["red"]["team_name"],
                "team_id": selected_team_records["red"].get("team_id"),
            },
        }
        with st.spinner("Calculando distribuição de kills..."):
            result = predict(request, bundle)
            event_id = save_prediction(request, result, database_url)
        st.session_state["last_prediction"] = {
            "request": request,
            "result": result,
            "event_id": event_id,
            "decision": None,
        }

    prediction_state = st.session_state.get("last_prediction")
    if not prediction_state:
        return
    request = prediction_state["request"]
    result = prediction_state["result"]
    event_id = prediction_state["event_id"]
    line = float(request["line"])
    if result["status"] == "blocked":
        st.error(result["reason"])
    else:
        st.success("Previsão calculada.")
        metric_columns = st.columns(4)
        metric_columns[0].metric("Média", f"{result['mean']:.1f}")
        metric_columns[1].metric("Mediana", result["median"])
        metric_columns[2].metric(
            f"Over {line:.1f}",
            f"{result['probability_over']:.1%}",
        )
        metric_columns[3].metric(
            f"Under {line:.1f}",
            f"{result['probability_under']:.1%}",
        )
        interval = result["prediction_interval_90"]
        st.write(
            f"Intervalo preditivo de 90%: {interval[0]} a "
            f"{interval[1]} kills."
        )
        directed_features = result.get("features") or {}
        detail_columns = st.columns(3)
        detail_columns[0].metric(
            "Duração esperada",
            f"{directed_features['duration_mean']:.1f} min",
        )
        detail_columns[1].metric(
            request["blue"]["team_name"],
            f"{directed_features['blue_mean']:.1f} kills",
        )
        detail_columns[2].metric(
            request["red"]["team_name"],
            f"{directed_features['red_mean']:.1f} kills",
        )
        st.caption(
            "Probabilidades sem vig da moneyline: "
            f"{request['blue']['team_name']} "
            f"{directed_features['p_blue_no_vig']:.1%} e "
            f"{request['red']['team_name']} "
            f"{directed_features['p_red_no_vig']:.1%}."
        )
        odds_columns = st.columns(2)
        odds_columns[0].metric(
            "Odd justa Over",
            f"{result['fair_odds_over']:.2f}",
        )
        odds_columns[1].metric(
            "Odd justa Under",
            f"{result['fair_odds_under']:.2f}",
        )
        with st.expander("Distribuição completa"):
            st.dataframe(
                {
                    "kills": list(range(len(result["pmf"]))),
                    "probabilidade": result["pmf"],
                },
                hide_index=True,
                width="stretch",
            )

        st.subheader("Decisão da aposta")
        if prediction_state["decision"]:
            decision_label = {
                "over": "Over, stake de 1 unidade.",
                "under": "Under, stake de 1 unidade.",
                "no_bet": "não apostar.",
            }[prediction_state["decision"]]
            st.success(f"Decisão salva: {decision_label}")
        else:
            st.write(
                "Confirme se esta previsão virou aposta. Over e Under entram "
                "automaticamente no histórico de validação."
            )
            decision_columns = st.columns(3)
            odds_over_saved = request.get("odds_over")
            odds_under_saved = request.get("odds_under")
            confirm_over = decision_columns[0].button(
                "Confirmar Over",
                disabled=not odds_over_saved or odds_over_saved <= 1,
                width="stretch",
                key=f"confirm_over_{event_id}",
            )
            confirm_under = decision_columns[1].button(
                "Confirmar Under",
                disabled=not odds_under_saved or odds_under_saved <= 1,
                width="stretch",
                key=f"confirm_under_{event_id}",
            )
            confirm_no_bet = decision_columns[2].button(
                "Não apostar",
                width="stretch",
                key=f"confirm_no_bet_{event_id}",
            )
            decision = None
            offered_odds = None
            if confirm_over:
                decision = "over"
                offered_odds = odds_over_saved
            elif confirm_under:
                decision = "under"
                offered_odds = odds_under_saved
            elif confirm_no_bet:
                decision = "no_bet"
            if decision:
                save_bet_decision(
                    event_id,
                    result["prediction_id"],
                    decision,
                    offered_odds,
                    database_url,
                )
                prediction_state["decision"] = decision
                st.session_state["last_prediction"] = prediction_state
                st.rerun()
            if not odds_over_saved or not odds_under_saved:
                st.caption(
                    "Para confirmar Over ou Under, informe a odd "
                    "correspondente e calcule novamente."
                )
    if database_url:
        st.info("Previsão salva no histórico permanente.")
    else:
        st.warning(
            "Registro local temporário. Configure o banco permanente antes "
            "de usar este ambiente para validação."
        )
    st.caption(
        f"Evento {event_id}. Modelo {result['model_version']}. "
        f"Dados até {result['data_cutoff']}."
    )


def _player_pool(roster_catalog: dict, league: str) -> dict[str, dict]:
    pool: dict[str, dict] = {}
    for team in (roster_catalog.get("teams") or {}).values():
        for player in team.get("players") or []:
            pool[player["player_id"]] = player
    return pool


def _render_predraft_prediction(
    bundle: dict,
    roster_catalog: dict,
    database_url: str | None,
) -> None:
    st.title("Total de kills pós-draft por mapa")
    st.caption(f"Versão da interface: {UI_RELEASE}")
    st.info(
        "Quando o total Pinnacle pós-draft estiver disponível, ele será a "
        "referência principal. Sem esse mercado, o modelo dirigido será usado "
        "como fallback."
    )
    st.write(
        "O confiômetro separa concordância de aposta, tendência, divergência "
        "e ausência de valor. O estado fica salvo no registro."
    )
    with st.container(border=True):
        league = st.selectbox("Liga", bundle["model"]["league_levels"])
        planned_default = datetime.now(ZoneInfo("America/Sao_Paulo"))
        match_columns = st.columns(3)
        planned_date = match_columns[0].date_input(
            "Data prevista",
            value=planned_default.date(),
        )
        planned_time = match_columns[1].time_input(
            "Horário de Brasília",
            value=planned_default.time(),
        )
        map_number = match_columns[2].number_input(
            "Número do mapa", min_value=1, max_value=7, value=1, step=1
        )
        available_teams = team_options(bundle, league)
        team_keys = [row["key"] for row in available_teams]
        team_by_key = {row["key"]: row for row in available_teams}
        if len(team_keys) < 2:
            st.error("A liga não possui duas equipes no snapshot atual.")
            st.stop()
        team_columns = st.columns(2)
        selected_teams: dict[str, dict] = {}
        for label, title, column, index in (
            ("team_a", "Equipe A", team_columns[0], 0),
            ("team_b", "Equipe B", team_columns[1], 1),
        ):
            selected_key = column.selectbox(
                title,
                team_keys,
                index=index,
                format_func=lambda key: team_label(
                    team_by_key[key],
                    float(bundle["sample_limits"]["team_effective_games"]),
                ),
                key=f"predraft_{label}",
            )
            selected_teams[label] = team_by_key[selected_key]
            if float(selected_teams[label]["effective_team_games"]) < float(
                bundle["sample_limits"]["team_effective_games"]
            ):
                column.warning(
                    "Equipe abaixo do limite mínimo de amostra. "
                    "A previsão fundamental poderá ser bloqueada."
                )

        player_pool = _player_pool(roster_catalog, league)
        player_ids = sorted(
            player_pool,
            key=lambda player_id: (
                player_pool[player_id].get("position", ""),
                player_pool[player_id].get("player_name", "").casefold(),
            ),
        )
        if len(player_ids) < 10:
            st.error("Catálogo de titulares insuficiente para esta liga.")
            st.stop()
        selected_starters: dict[str, list[str]] = {}
        starter_columns = st.columns(2)
        teams_catalog = roster_catalog.get("teams") or {}
        for label, title, column in (
            ("team_a", "Cinco titulares da equipe A", starter_columns[0]),
            ("team_b", "Cinco titulares da equipe B", starter_columns[1]),
        ):
            team_id = selected_teams[label].get("team_id")
            defaults = list(
                (teams_catalog.get(str(team_id)) or {}).get("latest_roster")
                or []
            )
            defaults = [value for value in defaults if value in player_pool]
            selected_starters[label] = column.multiselect(
                title,
                player_ids,
                default=defaults[:5],
                max_selections=5,
                format_func=lambda player_id: (
                    f"{player_pool[player_id]['player_name']} "
                    f"({player_pool[player_id].get('position', '?')})"
                ),
                key=f"predraft_starters_{label}_{team_id}",
            )

        st.subheader("Pinnacle")
        moneyline_columns = st.columns(2)
        moneyline_team_a = moneyline_columns[0].number_input(
            "Moneyline equipe A", min_value=0.0, value=0.0, step=0.01
        )
        moneyline_team_b = moneyline_columns[1].number_input(
            "Moneyline equipe B", min_value=0.0, value=0.0, step=0.01
        )
        pinnacle_available = st.checkbox(
            "Total Pinnacle disponível no snapshot pós-draft/live open",
            value=True,
        )
        st.caption(
            "Sem as duas odds Pinnacle completas, o fallback estrutural será "
            "ativado automaticamente."
        )
        pinnacle_line = pinnacle_over = pinnacle_under = None
        if pinnacle_available:
            pinnacle_columns = st.columns(3)
            pinnacle_line = pinnacle_columns[0].number_input(
                "Linha total Pinnacle", min_value=0.5, value=24.5, step=1.0
            )
            pinnacle_over = pinnacle_columns[1].number_input(
                "Odd Over Pinnacle", min_value=0.0, value=0.0, step=0.01
            )
            pinnacle_under = pinnacle_columns[2].number_input(
                "Odd Under Pinnacle", min_value=0.0, value=0.0, step=0.01
            )
        include_team_totals = st.checkbox("Informar team totals Pinnacle")
        team_total_values: dict[str, float | None] = {}
        if include_team_totals:
            for label, title in (("team_a", "Equipe A"), ("team_b", "Equipe B")):
                columns = st.columns(3)
                team_total_line = columns[0].number_input(
                    f"Linha team total {title}", min_value=0.5, value=12.5, step=1.0
                )
                team_total_over = columns[1].number_input(
                    f"Odd Over team total {title}", min_value=0.0, value=0.0, step=0.01
                )
                team_total_under = columns[2].number_input(
                    f"Odd Under team total {title}", min_value=0.0, value=0.0, step=0.01
                )
                if team_total_over > 1 and team_total_under > 1:
                    team_total_values[f"{label}_total_line"] = team_total_line
                    team_total_values[f"{label}_total_odds_over"] = (
                        team_total_over
                    )
                    team_total_values[f"{label}_total_odds_under"] = (
                        team_total_under
                    )

        st.subheader("Melhor cotação soft observada")
        st.caption(
            "O registro é first seen: a primeira cotação que você observou, "
            "não uma abertura oficial da casa."
        )
        soft_identity_columns = st.columns(3)
        bookmaker = soft_identity_columns[0].text_input(
            "Casa soft",
            placeholder="Ex.: Bet365",
        )
        quote_stage = soft_identity_columns[1].selectbox(
            "Estágio da cotação",
            ("first_seen", "update"),
            format_func=lambda value: (
                "Primeira observada" if value == "first_seen" else "Atualização"
            ),
        )
        market_gameid = soft_identity_columns[2].text_input(
            "Game ID do mercado (opcional)",
        )
        soft_columns = st.columns(3)
        soft_line = soft_columns[0].number_input(
            "Linha soft", min_value=0.5, value=24.5, step=1.0
        )
        soft_over = soft_columns[1].number_input(
            "Odd Over soft", min_value=0.0, value=0.0, step=0.01
        )
        soft_under = soft_columns[2].number_input(
            "Odd Under soft", min_value=0.0, value=0.0, step=0.01
        )
        additional_soft_quotes: list[dict[str, Any]] = []
        for quote_number in (2, 3):
            enabled = st.checkbox(
                f"Adicionar cotação soft {quote_number}",
                key=f"predraft_enable_soft_{quote_number}",
            )
            if enabled:
                extra_columns = st.columns(4)
                extra_bookmaker = extra_columns[0].text_input(
                    f"Casa soft {quote_number}",
                    placeholder="Ex.: Bet365",
                    key=f"predraft_bookmaker_{quote_number}",
                )
                extra_line = extra_columns[1].number_input(
                    f"Linha soft {quote_number}", min_value=0.5,
                    value=24.5, step=0.5,
                    key=f"predraft_soft_line_{quote_number}",
                )
                extra_over = extra_columns[2].number_input(
                    f"Odd Over soft {quote_number}", min_value=1.01,
                    value=1.90, step=0.01,
                    key=f"predraft_soft_over_{quote_number}",
                )
                extra_under = extra_columns[3].number_input(
                    f"Odd Under soft {quote_number}", min_value=1.01,
                    value=1.90, step=0.01,
                    key=f"predraft_soft_under_{quote_number}",
                )
                additional_soft_quotes.append({
                    "bookmaker": extra_bookmaker,
                    "line": float(extra_line),
                    "odds_over": float(extra_over),
                    "odds_under": float(extra_under),
                    "slot": quote_number,
                })
        submitted = st.button("Calcular previsão", type="primary", width="stretch")

    if submitted:
        if not bookmaker.strip():
            st.error("Informe a casa soft antes de salvar a cotação.")
            return
        if any(not quote["bookmaker"].strip() for quote in additional_soft_quotes):
            st.error("Informe a casa de cada cotação soft ativada.")
            return
        if len(selected_starters["team_a"]) != 5 or len(selected_starters["team_b"]) != 5:
            st.error("Selecione exatamente cinco titulares para cada equipe.")
            return
        planned_local = datetime.combine(
            planned_date, planned_time, tzinfo=ZoneInfo("America/Sao_Paulo")
        )
        pinnacle_complete = bool(
            pinnacle_available
            and pinnacle_line is not None
            and pinnacle_over is not None
            and pinnacle_under is not None
            and pinnacle_over > 1
            and pinnacle_under > 1
        )
        observed_at = datetime.now(timezone.utc).isoformat()
        request = {
            "league": league,
            "planned_at": planned_local.astimezone(timezone.utc).isoformat(),
            "quoted_at": observed_at,
            "observed_at": observed_at,
            "bookmaker": bookmaker.strip(),
            "quote_stage": quote_stage,
            "quote_source": "manual",
            "gameid": market_gameid.strip() or None,
            "analysis_timing": "postdraft_live_open",
            "map_number": int(map_number),
            "team_a": {
                "team_name": selected_teams["team_a"]["team_name"],
                "team_id": selected_teams["team_a"].get("team_id"),
                "starters": [player_pool[value] for value in selected_starters["team_a"]],
            },
            "team_b": {
                "team_name": selected_teams["team_b"]["team_name"],
                "team_id": selected_teams["team_b"].get("team_id"),
                "starters": [player_pool[value] for value in selected_starters["team_b"]],
            },
            "moneyline_team_a_odds": moneyline_team_a or None,
            "moneyline_team_b_odds": moneyline_team_b or None,
            "pinnacle_input_available": pinnacle_complete,
            "pinnacle_total_line": pinnacle_line if pinnacle_complete else None,
            "pinnacle_total_odds_over": (
                pinnacle_over if pinnacle_complete else None
            ),
            "pinnacle_total_odds_under": (
                pinnacle_under if pinnacle_complete else None
            ),
            "soft_line": soft_line,
            "soft_odds_over": soft_over or None,
            "soft_odds_under": soft_under or None,
            **team_total_values,
        }
        soft_quotes = [{
            "bookmaker": bookmaker.strip(),
            "line": float(soft_line),
            "odds_over": float(soft_over),
            "odds_under": float(soft_under),
            "slot": 1,
        }] + [
            {**quote, "bookmaker": quote["bookmaker"].strip()}
            for quote in additional_soft_quotes
        ]
        inference_bundle = dict(bundle)
        inference_bundle["roster_catalog"] = roster_catalog
        with st.spinner("Calculando distribuição de kills..."):
            result = predict(request, inference_bundle)
            shadow_rows = build_shadow_predictions(request, result, inference_bundle)
            operational_prediction = (
                build_operational_prediction(request, result, shadow_rows)
                if result.get("status") == "ok"
                else None
            )
            operational_quotes = []
            for quote in soft_quotes:
                quote_request = {
                    **request,
                    "bookmaker": quote["bookmaker"],
                    "soft_line": quote["line"],
                    "soft_odds_over": quote["odds_over"],
                    "soft_odds_under": quote["odds_under"],
                }
                quote_result = _result_at_soft_quote(
                    result, quote["line"], quote["odds_over"],
                    quote["odds_under"],
                )
                quote_shadow = build_shadow_predictions(
                    quote_request, quote_result, inference_bundle
                )
                quote_operational = (
                    build_operational_prediction(
                        quote_request, quote_result, quote_shadow
                    )
                    if result.get("status") == "ok"
                    else None
                )
                operational_quotes.append({
                    "quote": quote,
                    "request": quote_request,
                    "operational": quote_operational,
                })
            persisted_result = dict(result)
            persisted_result["shadow_predictions"] = shadow_rows
            result_with_shadow = dict(result)
            result_with_shadow["shadow_predictions"] = shadow_rows
            if operational_prediction is not None:
                for saved_result in (persisted_result, result_with_shadow):
                    saved_result["operational_prediction"] = (
                        operational_prediction
                    )
                    saved_result["prediction_source"] = (
                        operational_prediction["prediction_source"]
                    )
                    saved_result["model_agreement"] = (
                        operational_prediction["model_agreement"]
                    )
            event_id = save_prediction(request, persisted_result, database_url)
            quote_ids = []
            quote_persistence_error = None
            try:
                quote_ids = [
                    save_soft_quote_observation(
                        quote_row["request"],
                        event_id,
                        result.get("prediction_id", "blocked"),
                        database_url,
                    )
                    for quote_row in operational_quotes
                ]
            except Exception as error:
                quote_persistence_error = type(error).__name__
            quote_id = quote_ids[0] if quote_ids else None
            shadow_persistence_error = None
            try:
                save_shadow_predictions(
                    event_id,
                    result.get("prediction_id", "blocked"),
                    shadow_rows,
                    result.get("bet_status") == "blocked",
                    database_url,
                )
            except Exception as error:
                shadow_persistence_error = type(error).__name__
        st.session_state["last_predraft_prediction"] = {
            "request": request,
            "result": result_with_shadow,
            "event_id": event_id,
            "quote_id": quote_id,
            "quote_ids": quote_ids,
            "operational_quotes": operational_quotes,
            "decision": None,
            "decision_stake": None,
            "quote_persistence_error": quote_persistence_error,
            "shadow_persistence_error": shadow_persistence_error,
        }

    prediction_state = st.session_state.get("last_predraft_prediction")
    if not prediction_state:
        return
    request = prediction_state["request"]
    result = prediction_state["result"]
    event_id = prediction_state["event_id"]
    quote_id = prediction_state.get("quote_id")
    if prediction_state.get("quote_persistence_error"):
        st.warning(
            "A previsão foi calculada, mas as cotações soft não puderam ser "
            "salvas no banco permanente."
        )
    if prediction_state.get("shadow_persistence_error"):
        st.warning(
            "A previsão e os challengers foram preservados no evento, mas as "
            "tabelas analíticas de paper bets ainda não estão disponíveis."
        )
    if result["status"] == "blocked":
        st.error(result["reason"])
    else:
        operational = result.get("operational_prediction") or result
        st.success(
            "Previsão calculada. Referência ativa: "
            f"{operational.get('source_label', 'modelo estrutural')}."
        )
        operational_quotes = prediction_state.get("operational_quotes") or []
        st.subheader("Confiômetro e valor por cotação soft")
        for quote_row in operational_quotes:
            quote = quote_row["quote"]
            quote_operational = quote_row.get("operational")
            if quote_operational is None:
                continue
            st.markdown(
                f"**Cotação {quote['slot']} · {quote['bookmaker']} · "
                f"linha {quote['line']:.1f}**"
            )
            quote_metrics = st.columns(6)
            quote_metrics[0].metric(
                "Prob. Over", f"{quote_operational['probability_over']:.1%}"
            )
            quote_metrics[1].metric(
                "Odd justa Over", f"{quote_operational['fair_odds_over']:.2f}"
            )
            quote_metrics[2].metric(
                "EV Over", f"{quote_operational['ev_over']:+.1%}"
            )
            quote_metrics[3].metric(
                "Prob. Under", f"{quote_operational['probability_under']:.1%}"
            )
            quote_metrics[4].metric(
                "Odd justa Under", f"{quote_operational['fair_odds_under']:.2f}"
            )
            quote_metrics[5].metric(
                "EV Under", f"{quote_operational['ev_under']:+.1%}"
            )
            agreement = quote_operational.get("model_agreement") or {}
            message = agreement.get("message", "Confiômetro indisponível.")
            if agreement.get("alert_level") == "success":
                st.success(f"Confiômetro: {message}")
            elif agreement.get("alert_level") == "warning":
                st.warning(f"Confiômetro: {message}")
            else:
                st.info(f"Confiômetro: {message}")
        line = float(request["soft_line"])
        metrics = st.columns(4)
        metrics[0].metric("Média ativa", f"{operational['mean']:.1f}")
        metrics[1].metric("Mediana ativa", operational["median"])
        metrics[2].metric(
            f"Over {line:.1f}",
            f"{operational['probability_over']:.1%}",
        )
        metrics[3].metric(
            f"Under {line:.1f}",
            f"{operational['probability_under']:.1%}",
        )
        interval = operational["prediction_interval_90"]
        st.write(f"Intervalo preditivo de 90%: {interval[0]} a {interval[1]} kills.")
        features = result.get("features") or {}
        st.subheader("Diagnósticos do modelo estrutural")
        details = st.columns(3)
        details[0].metric("Duração esperada", f"{features['duration_mean']:.1f} min")
        details[1].metric(request["team_a"]["team_name"], f"{features['team_a_mean']:.1f} kills")
        details[2].metric(request["team_b"]["team_name"], f"{features['team_b_mean']:.1f} kills")
        shadow_rows = result.get("shadow_predictions") or []
        pinnacle_reference = next(
            (
                row
                for row in shadow_rows
                if row.get("model_id") == "market_implied_nb_exact"
            ),
            None,
        )
        if pinnacle_reference is not None:
            st.subheader("Comparação estrutural × Pinnacle")
            pinnacle_columns = st.columns(4)
            pinnacle_columns[0].metric(
                "Média estrutural",
                f"{result['mean']:.1f}",
            )
            pinnacle_columns[1].metric(
                "Média Pinnacle",
                f"{pinnacle_reference['mean']:.1f}",
            )
            pinnacle_columns[2].metric(
                "Estrutural menos Pinnacle",
                f"{result['mean'] - pinnacle_reference['mean']:+.1f} kills",
            )
            pinnacle_columns[3].metric(
                "Linha Pinnacle",
                f"{pinnacle_reference['diagnostics']['pinnacle_line']:.1f}",
            )
            st.caption(
                "Modelo estrutural comparado: Modelo dirigido + moneyline · "
                f"{result['model_version']} · Interface "
                f"{STRUCTURAL_REFERENCE_INTERFACE}."
            )
            agreement = operational["model_agreement"]
            if agreement["alert_level"] == "success":
                st.success(agreement["message"])
            elif agreement["alert_level"] == "warning":
                st.warning(agreement["message"])
            else:
                st.info(agreement["message"])
            agreement_columns = st.columns(2)
            pinnacle_side = agreement["pinnacle_preferred_side"]
            structural_side = agreement["structural_preferred_side"]
            pinnacle_signal = agreement.get("pinnacle_signal_side")
            structural_signal = agreement.get("structural_signal_side")
            agreement_columns[0].metric(
                "Leitura Pinnacle",
                pinnacle_signal.title() if pinnacle_signal else "Neutra",
                f"Melhor EV {agreement[f'pinnacle_ev_{pinnacle_side}']:+.1%}",
            )
            agreement_columns[1].metric(
                "Leitura estrutural",
                structural_signal.title() if structural_signal else "Neutra",
                f"Melhor EV {agreement[f'structural_ev_{structural_side}']:+.1%}",
            )
            st.caption(
                "Neutra significa diferença inferior a 1 ponto percentual "
                "contra a probabilidade no-vig da soft. A stake exibida "
                "segue a decisão combinada abaixo."
            )
            market_diagnostics = pinnacle_reference.get("diagnostics") or {}
            if market_diagnostics.get("team_a_implied_mean") is not None:
                st.subheader("Leitura dos team totals Pinnacle")
                team_total_columns = st.columns(4)
                team_total_columns[0].metric(
                    request["team_a"]["team_name"],
                    f"{market_diagnostics['team_a_implied_mean']:.1f} kills",
                )
                team_total_columns[1].metric(
                    request["team_b"]["team_name"],
                    f"{market_diagnostics['team_b_implied_mean']:.1f} kills",
                )
                team_total_columns[2].metric(
                    "Participação equipe A",
                    f"{market_diagnostics['team_a_implied_share']:.1%}",
                )
                team_total_columns[3].metric(
                    "Soma menos total",
                    f"{market_diagnostics['team_total_sum_gap']:+.1f} kills",
                )
        else:
            st.info(
                "Pinnacle pós-draft indisponível. Fallback ativo: Modelo "
                "dirigido + moneyline."
            )
            st.info(operational["model_agreement"]["message"])
        st.subheader("Valor da referência ativa na cotação soft")
        value_columns = st.columns(4)
        value_columns[0].metric(
            "Odd justa Over",
            f"{operational['fair_odds_over']:.2f}",
        )
        value_columns[1].metric(
            "Odd soft Over",
            f"{request['soft_odds_over']:.2f}",
        )
        value_columns[2].metric(
            "Odd justa Under",
            f"{operational['fair_odds_under']:.2f}",
        )
        value_columns[3].metric(
            "Odd soft Under",
            f"{request['soft_odds_under']:.2f}",
        )
        ev_columns = st.columns(2)
        ev_columns[0].metric("EV Over", f"{operational['ev_over']:+.1%}")
        ev_columns[1].metric("EV Under", f"{operational['ev_under']:+.1%}")
        st.subheader("Decisão combinada do paper bet")
        bet_blocked = result.get("bet_status") == "blocked"
        agreement = operational.get("model_agreement") or {}
        recommended_side = agreement.get("recommended_side")
        recommended_stake = agreement.get("recommended_stake")
        recommended_model = agreement.get("recommended_model")
        if bet_blocked:
            st.warning(
                "Não apostar agora. O cálculo de valor está visível apenas "
                "para auditoria porque a aposta foi bloqueada."
            )
        elif recommended_side is not None and recommended_stake is not None:
            side_label = recommended_side.title()
            recommended_soft_odds = request[f"soft_odds_{recommended_side}"]
            model_label = (
                "modelo estrutural"
                if recommended_model == "structural"
                else "Pinnacle"
            )
            st.success(
                f"Paper bet indicada: {side_label} {line:.1f} a "
                f"{recommended_soft_odds:.2f}, stake de "
                f"{recommended_stake:g}u. Referência do sinal: "
                f"{model_label}. Odd justa "
                f"{agreement['recommended_fair_odds']:.2f} e EV "
                f"{agreement['recommended_ev']:+.1%}."
            )
        else:
            st.info("Nenhum valor indicado. Não apostar.")
        st.caption(
            "Backtest semanal corrigido: 495 apostas, yield de 4,26%, "
            "drawdown máximo de 15,44u e intervalo bootstrap de 95% "
            "entre -4,34% e +12,95%."
        )
        for warning in result.get("warnings") or []:
            st.warning(warning)
        with st.expander("Distribuição completa"):
            st.dataframe(
                {
                    "kills": list(range(len(operational["pmf"]))),
                    "probabilidade": operational["pmf"],
                },
                hide_index=True,
                width="stretch",
            )
        st.subheader("Decisão da aposta")
        if bet_blocked:
            for reason in result.get("bet_block_reasons") or []:
                st.error(reason)
            st.caption(
                "A previsão e o EV permanecem visíveis para auditoria, "
                "mas a confirmação fica bloqueada."
            )
        elif prediction_state["decision"]:
            if prediction_state["decision"] == "no_bet":
                decision_label = "não apostar"
            else:
                saved_stake = prediction_state.get("decision_stake") or 1.0
                side_label = prediction_state["decision"].title()
                decision_label = f"{side_label}, stake de {saved_stake:g}u"
            st.success(f"Decisão salva: {decision_label}.")
        else:
            decision_columns = st.columns(3)
            confirm_over = decision_columns[0].button(
                "Confirmar Over", width="stretch", key=f"predraft_over_{event_id}"
            )
            confirm_under = decision_columns[1].button(
                "Confirmar Under", width="stretch", key=f"predraft_under_{event_id}"
            )
            confirm_no_bet = decision_columns[2].button(
                "Não apostar", width="stretch", key=f"predraft_no_bet_{event_id}"
            )
            decision = (
                "over" if confirm_over else
                "under" if confirm_under else
                "no_bet" if confirm_no_bet else None
            )
            if decision:
                offered_odds = None
                if decision == "over":
                    offered_odds = request["soft_odds_over"]
                elif decision == "under":
                    offered_odds = request["soft_odds_under"]
                agreement = operational.get("model_agreement") or {}
                decision_stake = 1.0
                if (
                    decision == agreement.get("recommended_side")
                    and agreement.get("recommended_stake") is not None
                ):
                    decision_stake = float(agreement["recommended_stake"])
                save_bet_decision(
                    event_id,
                    result["prediction_id"],
                    decision,
                    offered_odds,
                    database_url,
                    stake=decision_stake,
                )
                if quote_id:
                    save_quote_outcome(
                        quote_id,
                        {
                            "execution_status": (
                                "accepted" if decision != "no_bet" else "not_attempted"
                            ),
                            "executed_side": decision if decision != "no_bet" else None,
                            "requested_odds": offered_odds,
                            "requested_stake": (
                                decision_stake if decision != "no_bet" else None
                            ),
                            "accepted_odds": offered_odds,
                            "accepted_stake": (
                                decision_stake if decision != "no_bet" else None
                            ),
                        },
                        database_url,
                    )
                prediction_state["decision"] = decision
                prediction_state["decision_stake"] = (
                    decision_stake if decision != "no_bet" else None
                )
                st.session_state["last_predraft_prediction"] = prediction_state
                st.rerun()
    st.caption(
        f"Evento {event_id}. Referência {result.get('prediction_source')}. "
        f"Modelo estrutural {result['model_version']}. "
        f"Dados até {result['data_cutoff']}."
    )


def _render_soft_quote_history(database_url: str | None) -> None:
    st.title("Cotações soft observadas")
    st.caption(
        "Cada linha é uma observação manual. First seen não significa "
        "abertura oficial da casa."
    )
    quotes = load_soft_quote_observations(database_url)
    if quotes.empty:
        st.info("Nenhuma cotação soft foi registrada.")
        return
    readiness = assess_soft_model_readiness(quotes.to_dict(orient="records"))
    readiness_columns = st.columns(3)
    readiness_columns[0].metric(
        "First seen",
        readiness["first_seen_quotes"],
        "meta: 500",
    )
    readiness_columns[1].metric("Ligas", readiness["leagues"], "meta: 3")
    readiness_columns[2].metric(
        "Modelo B",
        "Pronto" if readiness["ready_to_train_model_b"] else "Coletando",
    )
    display_columns = [
        "observed_at", "bookmaker", "league", "blue_team", "red_team",
        "map_number", "quote_stage", "line", "odds_over", "odds_under",
        "pinnacle_available", "execution_status", "executed_side",
        "accepted_odds", "accepted_stake", "profit", "clv",
    ]
    st.dataframe(
        quotes[[column for column in display_columns if column in quotes.columns]],
        hide_index=True,
        width="stretch",
    )
    labels = {
        row.quote_id: (
            f"{row.bookmaker} | {row.blue_team} x {row.red_team} | "
            f"mapa {row.map_number} | {row.observed_at}"
        )
        for row in quotes.itertuples()
    }
    quote_id = st.selectbox(
        "Cotação para atualizar",
        list(labels),
        format_func=labels.get,
    )
    selected_soft_line = float(
        quotes.loc[quotes["quote_id"] == quote_id, "line"].iloc[0]
    )
    with st.container(border=True):
        status = st.selectbox(
            "Status de execução",
            (
                "pending", "not_attempted", "accepted", "rejected",
                "win", "loss", "void",
            ),
        )
        side = st.selectbox("Lado executado", ("over", "under"))
        execution_columns = st.columns(4)
        requested_odds = execution_columns[0].number_input(
            "Odd solicitada", min_value=0.0, value=0.0, step=0.01
        )
        requested_stake = execution_columns[1].number_input(
            "Stake solicitada", min_value=0.0, value=1.0, step=0.5
        )
        accepted_odds = execution_columns[2].number_input(
            "Odd aceita", min_value=0.0, value=0.0, step=0.01
        )
        accepted_stake = execution_columns[3].number_input(
            "Stake aceita", min_value=0.0, value=1.0, step=0.5
        )
        pinnacle_columns = st.columns(3)
        final_line = pinnacle_columns[0].number_input(
            "Linha Pinnacle final", min_value=0.0, value=0.0, step=0.5
        )
        final_over = pinnacle_columns[1].number_input(
            "Odd Over Pinnacle final", min_value=0.0, value=0.0, step=0.01
        )
        final_under = pinnacle_columns[2].number_input(
            "Odd Under Pinnacle final", min_value=0.0, value=0.0, step=0.01
        )
        notes = st.text_input("Observações")
        if st.button("Salvar execução e liquidação", type="primary"):
            if final_line > 0 and abs(final_line - selected_soft_line) > 1e-9:
                st.error(
                    "O CLV exige a Pinnacle final na mesma linha da cotaÃ§Ã£o soft."
                )
                return
            accepted = status in {"accepted", "win", "loss"}
            settled = status in {"win", "loss", "void"}
            stake_value = accepted_stake if accepted else None
            odds_value = accepted_odds if accepted else None
            profit = None
            if status == "win":
                profit = accepted_stake * (accepted_odds - 1)
            elif status == "loss":
                profit = -accepted_stake
            elif status == "void":
                profit = 0.0
            closing_odds = final_over if side == "over" else final_under
            clv = (
                accepted_odds / closing_odds - 1
                if accepted and accepted_odds > 1 and closing_odds > 1
                else None
            )
            save_quote_outcome(
                quote_id,
                {
                    "execution_status": status,
                    "executed_side": side if accepted else None,
                    "requested_odds": requested_odds or None,
                    "requested_stake": requested_stake or None,
                    "accepted_odds": odds_value,
                    "accepted_stake": stake_value,
                    "settled_at": (
                        datetime.now(timezone.utc).isoformat() if settled else None
                    ),
                    "profit": profit,
                    "final_pinnacle_time": (
                        datetime.now(timezone.utc).isoformat()
                        if final_line > 0 and final_over > 1 and final_under > 1
                        else None
                    ),
                    "final_pinnacle_line": final_line or None,
                    "final_pinnacle_odds_over": final_over or None,
                    "final_pinnacle_odds_under": final_under or None,
                    "clv": clv,
                    "notes": notes or None,
                },
                database_url,
            )
            st.success("Execução atualizada.")
            st.rerun()


def _render_synthetic_pinnacle(
    active_bundle: dict[str, Any],
    database_url: str | None,
) -> None:
    st.title("Pinnacle sintética pré-abertura")
    st.caption(
        "Estima diretamente a linha principal e as odds finais prematch da Pinnacle usando somente "
        "dados estruturais disponíveis antes da abertura. Não usa moneyline, "
        "lado azul/vermelho ou cotação soft como feature."
    )
    if not SYNTHETIC_PINNACLE_PATH.exists():
        st.error("Bundle da Pinnacle sintética não encontrado.")
        return
    synthetic_bundle = load_synthetic_pinnacle_bundle(SYNTHETIC_PINNACLE_PATH)
    teams = synthetic_bundle.get("inference_teams") or active_bundle.get("teams") or []
    leagues = sorted({str(team["league_canonical"]) for team in teams})
    league = st.selectbox("Liga sintética", leagues)
    league_teams = [
        team for team in teams if str(team["league_canonical"]) == league
    ]
    labels = {
        team["key"]: f"{team['team_name']} | {team['effective_team_games']:.1f} jogos efetivos"
        for team in league_teams
    }
    selection_columns = st.columns(3)
    team_a_key = selection_columns[0].selectbox(
        "Equipe 1", list(labels), format_func=labels.get, key="synthetic_team_a"
    )
    team_b_options = [key for key in labels if key != team_a_key]
    team_b_key = selection_columns[1].selectbox(
        "Equipe 2",
        team_b_options,
        format_func=labels.get,
        key="synthetic_team_b",
    )
    map_number = selection_columns[2].number_input(
        "Mapa da série", min_value=1, max_value=5, value=1, step=1,
        key="synthetic_map_number",
    )
    quote_columns = st.columns(4)
    bookmaker = quote_columns[0].text_input(
        "Casa soft sintética", placeholder="Ex.: Bet365"
    )
    soft_line = quote_columns[1].number_input(
        "Linha soft sintética", min_value=0.5, value=25.5, step=0.5
    )
    soft_odds_over = quote_columns[2].number_input(
        "Odd Over soft sintética", min_value=1.01, value=1.90, step=0.01
    )
    soft_odds_under = quote_columns[3].number_input(
        "Odd Under soft sintética", min_value=1.01, value=1.90, step=0.01
    )
    additional_quotes: list[dict[str, Any]] = []
    for quote_number in (2, 3):
        enabled = st.checkbox(
            f"Adicionar cotação sintética {quote_number}",
            key=f"synthetic_enable_quote_{quote_number}",
        )
        if enabled:
            extra_columns = st.columns(4)
            extra_bookmaker = extra_columns[0].text_input(
                f"Casa soft sintética {quote_number}",
                placeholder="Ex.: Bet365",
                key=f"synthetic_bookmaker_{quote_number}",
            )
            extra_line = extra_columns[1].number_input(
                f"Linha soft sintética {quote_number}", min_value=0.5,
                value=25.5, step=0.5,
                key=f"synthetic_line_{quote_number}",
            )
            extra_over = extra_columns[2].number_input(
                f"Odd Over soft sintética {quote_number}", min_value=1.01,
                value=1.90, step=0.01,
                key=f"synthetic_over_{quote_number}",
            )
            extra_under = extra_columns[3].number_input(
                f"Odd Under soft sintética {quote_number}", min_value=1.01,
                value=1.90, step=0.01,
                key=f"synthetic_under_{quote_number}",
            )
            additional_quotes.append({
                "bookmaker": extra_bookmaker,
                "line": float(extra_line),
                "odds_over": float(extra_over),
                "odds_under": float(extra_under),
                "slot": quote_number,
            })
    timing_columns = st.columns(2)
    local_now = datetime.now(ZoneInfo("America/Sao_Paulo"))
    planned_date = timing_columns[0].date_input(
        "Data planejada sintética", value=(local_now + timedelta(days=1)).date()
    )
    planned_time = timing_columns[1].time_input(
        "Horário planejado sintético",
        value=local_now.replace(second=0, microsecond=0).time(),
    )
    if not st.button("Calcular Pinnacle sintética", type="primary"):
        return
    if not bookmaker.strip():
        st.error("Informe a casa soft antes de calcular.")
        return
    if any(not quote["bookmaker"].strip() for quote in additional_quotes):
        st.error("Informe a casa de cada cotação sintética ativada.")
        return
    team_index = {team["key"]: team for team in league_teams}
    team_a = team_index[team_a_key]
    team_b = team_index[team_b_key]
    soft_quotes = [{
        "bookmaker": bookmaker.strip(),
        "line": float(soft_line),
        "odds_over": float(soft_odds_over),
        "odds_under": float(soft_odds_under),
        "slot": 1,
    }] + [
        {**quote, "bookmaker": quote["bookmaker"].strip()}
        for quote in additional_quotes
    ]
    if len(soft_quotes) == 3:
        results = predict_synthetic_pinnacle_quotes(
            team_a, team_b, league, int(map_number), soft_quotes,
            synthetic_bundle,
        )
    else:
        results = [
            predict_synthetic_pinnacle(
                team_a, team_b, league, int(map_number), quote["line"],
                quote["odds_over"], quote["odds_under"], synthetic_bundle,
            )
            for quote in soft_quotes
        ]
    result = results[0]
    metric_columns = st.columns(4)
    metric_columns[0].metric(
        "Linha Pinnacle final esperada",
        f"{result.get('predicted_final_line', result.get('predicted_last_mu')):.1f}",
    )
    metric_columns[1].metric(
        "Intervalo conservador",
        f"{result.get('predicted_final_line_low', result.get('predicted_last_mu_low')):.1f} "
        f"a {result.get('predicted_final_line_high', result.get('predicted_last_mu_high')):.1f}",
    )
    metric_columns[2].metric(
        "EV conservador Over", f"{result['conservative_ev_over']:+.1%}"
    )
    metric_columns[3].metric(
        "EV conservador Under", f"{result['conservative_ev_under']:+.1%}"
    )
    probability_columns = st.columns(4)
    probability_columns[0].metric(
        "Probabilidade Over", f"{result['probability_over']:.1%}"
    )
    probability_columns[1].metric("Odd justa Over", f"{result['fair_odds_over']:.2f}")
    probability_columns[2].metric(
        "Probabilidade Under", f"{result['probability_under']:.1%}"
    )
    probability_columns[3].metric("Odd justa Under", f"{result['fair_odds_under']:.2f}")
    if result.get("predicted_final_odds_over") is not None:
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
    st.subheader("Confiômetro e valor por cotação soft")
    for quote, quote_result in zip(soft_quotes, results):
        st.markdown(
            f"**Cotação {quote['slot']} · {quote['bookmaker']} · "
            f"linha {quote['line']:.1f}**"
        )
        quote_metrics = st.columns(6)
        quote_metrics[0].metric(
            "Odd justa Over", f"{quote_result['fair_odds_over']:.2f}"
        )
        quote_metrics[1].metric(
            "EV Over", f"{quote_result['ev_over']:+.1%}"
        )
        quote_metrics[2].metric(
            "EV conservador Over",
            f"{quote_result['conservative_ev_over']:+.1%}",
        )
        quote_metrics[3].metric(
            "Odd justa Under", f"{quote_result['fair_odds_under']:.2f}"
        )
        quote_metrics[4].metric(
            "EV Under", f"{quote_result['ev_under']:+.1%}"
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
    st.caption(
        "O modelo prevê diretamente a linha principal e os preços finais. "
        "As probabilidades nas linhas soft usam a curva histórica de preços "
        "da Pinnacle. Este modo é comparação manual, não autorização automática."
    )
    return
    observed_at = datetime.now(timezone.utc).isoformat()
    planned_at = datetime.combine(
        planned_date,
        planned_time,
        tzinfo=ZoneInfo("America/Sao_Paulo"),
    ).astimezone(timezone.utc).isoformat()
    try:
        for quote_row, quote_result in zip(soft_quotes, results):
            quote = {
                "observed_at": observed_at,
                "bookmaker": quote_row["bookmaker"],
                "league": league,
                "planned_at": planned_at,
                "map_number": int(map_number),
                "quote_stage": "first_seen",
                "soft_line": quote_row["line"],
                "soft_odds_over": quote_row["odds_over"],
                "soft_odds_under": quote_row["odds_under"],
                "pinnacle_input_available": False,
                "quote_source": "manual_synthetic_pinnacle",
                "team_a": {"team_name": team_a["team_name"], "team_id": team_a.get("team_id")},
                "team_b": {"team_name": team_b["team_name"], "team_id": team_b.get("team_id")},
            }
            quote_id = save_soft_quote_observation(quote, database_url=database_url)
            save_pinnacle_forecast(quote_id, quote_result, database_url)
    except Exception:
        st.warning(
            "A previsão foi calculada, mas a cotação e o forecast não puderam "
            "ser salvos no banco permanente."
        )
    else:
        st.success(f"{len(results)} cotação(ões) e forecasts sintéticos registrados.")


def run_vault_app() -> None:
    st.set_page_config(
        page_title="Vault Corp | LoL Kills",
        page_icon=None,
        layout="wide",
        initial_sidebar_state="collapsed",
    )
    _apply_theme()
    bundle = None
    roster_catalog = None
    if BUNDLE_PATH.exists():
        bundle = _load_active_bundle(BUNDLE_PATH.stat().st_mtime_ns)
    if ROSTER_CATALOG_PATH.exists():
        roster_catalog = _load_roster_catalog(
            ROSTER_CATALOG_PATH.stat().st_mtime_ns
        )
    _render_hero(bundle)
    _render_synthetic_pinnacle(bundle or {}, None)
    return
    view = st.radio(
        "Área",
        (
            "Previsão", "Cotações soft", "Apostas registradas",
            "Tracking temporal",
            "Pinnacle sintética",
        ),
        horizontal=True,
        label_visibility="collapsed",
    )
    database_url = _database_url()
    if view == "Apostas registradas":
        _render_bet_history(database_url)
    elif view == "Cotações soft":
        _render_soft_quote_history(database_url)
    elif view == "Tracking temporal":
        if not TRACKING_PATH.exists():
            st.error(
                "As séries temporais ainda não foram geradas. "
                "Execute o script 31."
            )
            return
        render_tracking_page(load_tracking_data(TRACKING_PATH))
    elif view == "Pinnacle sintética":
        if bundle is None:
            st.error("Bundle estrutural não encontrado.")
            return
        _render_synthetic_pinnacle(bundle, database_url)
    else:
        if bundle is None or roster_catalog is None:
            st.error(
                "O bundle ou o catálogo de titulares não está disponível. "
                "O deploy está incompleto."
            )
            return
        _render_predraft_prediction(bundle, roster_catalog, database_url)
    st.markdown(
        '<p class="model-note">Uso informativo. Probabilidade não garante '
        "resultado. Quando houver pouca amostra, o sistema bloqueia a "
        "aposta.</p>",
        unsafe_allow_html=True,
    )
