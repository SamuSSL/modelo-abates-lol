from __future__ import annotations

import os
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd
import streamlit as st
from streamlit.errors import StreamlitSecretNotFoundError

from app.lolkills_inference import load_bundle, predict
from app.persistence import (
    load_bet_history,
    save_bet_decision,
    save_prediction,
    save_shadow_predictions,
)
from app.shadow_models import build_shadow_predictions
from app.tracking import load_tracking_data, render_tracking_page
from app.ui_options import team_label, team_options


BUNDLE_PATH = Path("app_data/model_bundle.json")
ROSTER_CATALOG_PATH = Path("app_data/roster_catalog.json")
TRACKING_PATH = Path("app_data/time_series_tracking.csv.gz")
UI_RELEASE = "predraft-ev-v2-2026-08-04"


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
    model_label = "Vault Corp · Modelo dirigido + moneyline"
    if bundle:
        model_label = (
            f"Vault Corp · Modelo dirigido + moneyline · "
            f"{bundle['metadata']['model_version']} · Interface {UI_RELEASE}"
        )
    st.markdown(
        f"""
        <section class="vault-hero">
          <h1 class="vault-title">LoL Kills Intelligence</h1>
          <p class="vault-subtitle">
            Probabilidades pré-mapa para o total de abates, com histórico
            integral das apostas usadas na validação prospectiva.
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
        "moneyline, ratings derivados, duração, intervalo preditivo, pace, "
        "cutoff e identificadores."
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
    st.title("Total de kills pré-draft por mapa")
    st.caption(f"Versão da interface: {UI_RELEASE}")
    st.info(
        "Paper betting prospectivo. O directed é o melhor candidato testado, "
        "mas a vantagem econômica ainda não foi confirmada a 95%."
    )
    st.write(
        "O directed semanal continua sendo o único modelo exibido. "
        "Os challengers são calculados e registrados sem aparecer na interface."
    )
    with st.container(border=True):
        league = st.selectbox("Liga", bundle["model"]["league_levels"])
        planned_default = datetime.now(
            ZoneInfo("America/Sao_Paulo")
        ) + timedelta(minutes=35)
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
            "Total Pinnacle disponível no snapshot T-45/T-30", value=True
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
                team_total_values[f"{label}_total_line"] = columns[0].number_input(
                    f"Linha team total {title}", min_value=0.5, value=12.5, step=1.0
                )
                team_total_values[f"{label}_total_odds_over"] = columns[1].number_input(
                    f"Odd Over team total {title}", min_value=0.0, value=0.0, step=0.01
                )
                team_total_values[f"{label}_total_odds_under"] = columns[2].number_input(
                    f"Odd Under team total {title}", min_value=0.0, value=0.0, step=0.01
                )

        st.subheader("Melhor cotação soft")
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
        submitted = st.button("Calcular previsão", type="primary", width="stretch")

    if submitted:
        if len(selected_starters["team_a"]) != 5 or len(selected_starters["team_b"]) != 5:
            st.error("Selecione exatamente cinco titulares para cada equipe.")
            return
        planned_local = datetime.combine(
            planned_date, planned_time, tzinfo=ZoneInfo("America/Sao_Paulo")
        )
        request = {
            "league": league,
            "planned_at": planned_local.astimezone(timezone.utc).isoformat(),
            "quoted_at": datetime.now(timezone.utc).isoformat(),
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
            "pinnacle_total_line": pinnacle_line if pinnacle_available else None,
            "pinnacle_total_odds_over": pinnacle_over if pinnacle_available else None,
            "pinnacle_total_odds_under": pinnacle_under if pinnacle_available else None,
            "soft_line": soft_line,
            "soft_odds_over": soft_over or None,
            "soft_odds_under": soft_under or None,
            **team_total_values,
        }
        inference_bundle = dict(bundle)
        inference_bundle["roster_catalog"] = roster_catalog
        with st.spinner("Calculando distribuição de kills..."):
            result = predict(request, inference_bundle)
            shadow_rows = build_shadow_predictions(request, result, inference_bundle)
            persisted_result = dict(result)
            persisted_result["shadow_predictions"] = shadow_rows
            event_id = save_prediction(request, persisted_result, database_url)
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
            "result": result,
            "event_id": event_id,
            "decision": None,
            "shadow_persistence_error": shadow_persistence_error,
        }

    prediction_state = st.session_state.get("last_predraft_prediction")
    if not prediction_state:
        return
    request = prediction_state["request"]
    result = prediction_state["result"]
    event_id = prediction_state["event_id"]
    if prediction_state.get("shadow_persistence_error"):
        st.warning(
            "A previsão e os challengers foram preservados no evento, mas as "
            "tabelas analíticas de paper bets ainda não estão disponíveis."
        )
    if result["status"] == "blocked":
        st.error(result["reason"])
    else:
        st.success("Previsão calculada.")
        line = float(request["soft_line"])
        metrics = st.columns(4)
        metrics[0].metric("Média", f"{result['mean']:.1f}")
        metrics[1].metric("Mediana", result["median"])
        metrics[2].metric(f"Over {line:.1f}", f"{result['probability_over']:.1%}")
        metrics[3].metric(f"Under {line:.1f}", f"{result['probability_under']:.1%}")
        interval = result["prediction_interval_90"]
        st.write(f"Intervalo preditivo de 90%: {interval[0]} a {interval[1]} kills.")
        features = result.get("features") or {}
        details = st.columns(3)
        details[0].metric("Duração esperada", f"{features['duration_mean']:.1f} min")
        details[1].metric(request["team_a"]["team_name"], f"{features['team_a_mean']:.1f} kills")
        details[2].metric(request["team_b"]["team_name"], f"{features['team_b_mean']:.1f} kills")
        st.subheader("Valor na cotação soft")
        value_columns = st.columns(4)
        value_columns[0].metric(
            "Odd justa Over",
            f"{result['fair_odds_over']:.2f}",
        )
        value_columns[1].metric(
            "Odd soft Over",
            f"{request['soft_odds_over']:.2f}",
        )
        value_columns[2].metric(
            "Odd justa Under",
            f"{result['fair_odds_under']:.2f}",
        )
        value_columns[3].metric(
            "Odd soft Under",
            f"{request['soft_odds_under']:.2f}",
        )
        ev_columns = st.columns(2)
        ev_columns[0].metric("EV Over", f"{result['ev_over']:+.1%}")
        ev_columns[1].metric("EV Under", f"{result['ev_under']:+.1%}")
        bet_blocked = result.get("bet_status") == "blocked"
        best_side = "Over" if result["ev_over"] >= result["ev_under"] else "Under"
        best_ev = max(result["ev_over"], result["ev_under"])
        best_fair_odds = (
            result["fair_odds_over"]
            if best_side == "Over"
            else result["fair_odds_under"]
        )
        best_soft_odds = (
            request["soft_odds_over"]
            if best_side == "Over"
            else request["soft_odds_under"]
        )
        if bet_blocked:
            st.warning(
                "Não apostar agora. O cálculo de valor está visível apenas "
                "para auditoria porque a aposta foi bloqueada."
            )
        elif best_ev > 0:
            st.success(
                f"Paper bet indicada: {best_side} {line:.1f} a "
                f"{best_soft_odds:.2f}. Odd justa {best_fair_odds:.2f} e "
                f"EV {best_ev:+.1%}."
            )
        else:
            st.info(
                "Sem valor positivo nas odds informadas. Não fazer paper bet."
            )
        st.caption(
            "Backtest semanal corrigido: 495 apostas, yield de 4,26%, "
            "drawdown máximo de 15,44u e intervalo bootstrap de 95% "
            "entre -4,34% e +12,95%."
        )
        for warning in result.get("warnings") or []:
            st.warning(warning)
        with st.expander("Distribuição completa"):
            st.dataframe(
                {"kills": list(range(len(result["pmf"]))), "probabilidade": result["pmf"]},
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
            decision_label = {
                "over": "Over, stake de 1 unidade",
                "under": "Under, stake de 1 unidade",
                "no_bet": "não apostar",
            }[prediction_state["decision"]]
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
                save_bet_decision(
                    event_id, result["prediction_id"], decision, offered_odds, database_url
                )
                prediction_state["decision"] = decision
                st.session_state["last_predraft_prediction"] = prediction_state
                st.rerun()
    st.caption(
        f"Evento {event_id}. Modelo {result['model_version']}. "
        f"Dados até {result['data_cutoff']}."
    )


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
    view = st.radio(
        "Área",
        ("Previsão", "Apostas registradas", "Tracking temporal"),
        horizontal=True,
        label_visibility="collapsed",
    )
    database_url = _database_url()
    if view == "Apostas registradas":
        _render_bet_history(database_url)
    elif view == "Tracking temporal":
        if not TRACKING_PATH.exists():
            st.error(
                "As séries temporais ainda não foram geradas. "
                "Execute o script 31."
            )
            return
        render_tracking_page(load_tracking_data(TRACKING_PATH))
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
