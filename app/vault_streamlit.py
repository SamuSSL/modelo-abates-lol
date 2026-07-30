from __future__ import annotations

import os
from datetime import datetime, timezone
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
)
from app.tracking import load_tracking_data, render_tracking_page
from app.ui_options import team_label, team_options


BUNDLE_PATH = Path("app_data/model_bundle.json")
TRACKING_PATH = Path("app_data/time_series_tracking.csv.gz")


@st.cache_resource
def _load_active_bundle(bundle_mtime_ns: int):
    return load_bundle(BUNDLE_PATH)


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
    model_label = "Vault Corp · Modelo liga + pace"
    if bundle:
        model_label = (
            f"Vault Corp · Modelo liga + pace · "
            f"{bundle['metadata']['model_version']}"
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
            "probabilidade_modelo",
            "chosen_fair_odds",
            "ev_registro",
            "predicted_mean",
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
            "probabilidade_modelo": "Prob. modelo",
            "chosen_fair_odds": "Odd justa",
            "ev_registro": "EV",
            "predicted_mean": "Média prevista",
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
        "intervalo preditivo, pace, cutoff e identificadores."
    )


def _render_prediction(bundle: dict, database_url: str | None) -> None:
    st.title("Total de kills por mapa")
    st.write(
        "Modelo pré-mapa baseado na liga e no ritmo histórico recente das "
        "duas equipes. Draft e campeões não entram nesta versão."
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

        st.subheader("Linha e odds")
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


def run_vault_app() -> None:
    st.set_page_config(
        page_title="Vault Corp | LoL Kills",
        page_icon=None,
        layout="wide",
        initial_sidebar_state="collapsed",
    )
    _apply_theme()
    bundle = None
    if BUNDLE_PATH.exists():
        bundle = _load_active_bundle(BUNDLE_PATH.stat().st_mtime_ns)
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
        if bundle is None:
            st.error(
                "O bundle do modelo não está disponível. "
                "O deploy está incompleto."
            )
            return
        _render_prediction(bundle, database_url)
    st.markdown(
        '<p class="model-note">Uso informativo. Probabilidade não garante '
        "resultado. Quando houver pouca amostra, o sistema bloqueia a "
        "aposta.</p>",
        unsafe_allow_html=True,
    )
