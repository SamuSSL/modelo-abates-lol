from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import streamlit as st
from streamlit.errors import StreamlitSecretNotFoundError

from app.lolkills_inference import POSITIONS, load_bundle, predict
from app.persistence import save_prediction
from app.tracking import load_tracking_data, render_tracking_page
from app.ui_options import (
    player_label,
    player_options,
    team_label,
    team_options,
)


st.set_page_config(
    page_title="LoL Kills",
    page_icon=None,
    layout="wide",
    initial_sidebar_state="collapsed",
)

st.markdown(
    """
    <style>
      :root {
        --surface: #101826;
        --surface-soft: #172234;
        --border: #2c3a50;
        --text: #f3f6fa;
        --muted: #b8c3d3;
        --accent: #32c6a6;
      }
      .stApp { background: var(--surface); color: var(--text); }
      .block-container { max-width: 1120px; padding-top: 2rem; }
      [data-testid="stForm"] {
        background: var(--surface-soft);
        border: 1px solid var(--border);
        border-radius: 12px;
        padding: 1rem;
      }
      .stButton button, [data-testid="stFormSubmitButton"] button {
        min-height: 44px;
      }
      .model-note { color: var(--muted); line-height: 1.6; }
      @media (max-width: 700px) {
        .block-container { padding: 1rem; }
      }
    </style>
    """,
    unsafe_allow_html=True,
)

view = st.radio(
    "Área",
    ("Previsão", "Tracking temporal"),
    horizontal=True,
    label_visibility="collapsed",
)
if view == "Tracking temporal":
    tracking_path = Path("app_data/time_series_tracking.csv.gz")
    if not tracking_path.exists():
        st.error(
            "As séries temporais ainda não foram geradas. "
            "Execute o script 31."
        )
        st.stop()
    render_tracking_page(load_tracking_data(tracking_path))
    st.stop()

BUNDLE_PATH = Path("app_data/model_bundle.json")
if not BUNDLE_PATH.exists():
    st.error("O bundle do modelo não está disponível. O deploy está incompleto.")
    st.stop()


@st.cache_resource
def get_bundle(bundle_mtime_ns):
    return load_bundle(BUNDLE_PATH)


bundle = get_bundle(BUNDLE_PATH.stat().st_mtime_ns)
player_rows = bundle["players"]
champions = sorted(
    champion
    for champion in bundle["taxonomy"]
    if bundle["champion_samples"].get(champion, 0)
    >= bundle["sample_limits"]["champion_effective_games"]
)


def resolve_player_record(player_name, position, team_name):
    position_matches = [
        row
        for row in player_rows
        if row["player_name"] == player_name and row["position"] == position
    ]
    team_matches = [
        row for row in position_matches if row.get("team_name") == team_name
    ]
    return (team_matches or position_matches)[0]


st.title("Total de kills por mapa")
st.markdown(
    "Previsão pós-draft. O modelo pode bloquear a análise quando a amostra "
    "de equipe, jogador ou campeão for insuficiente.",
    help="Bloqueio significa que não há base histórica suficiente para apostar.",
)

with st.container(border=True):
    st.subheader("Partida")
    match_columns = st.columns(4)
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
    league = match_columns[0].selectbox(
        "Liga",
        league_options,
        index=default_league_index,
    )
    available_teams = team_options(bundle, league)
    team_keys = [row["key"] for row in available_teams]
    team_by_key = {row["key"]: row for row in available_teams}
    team_limit = float(bundle["sample_limits"]["team_effective_games"])
    if len(team_keys) < 2:
        st.error("A liga não possui duas equipes no snapshot atual.")
        st.stop()
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

    team_columns = st.columns(2)
    selected_teams = {}
    selected_team_records = {}
    selected_players = {}
    selected_player_records = {}
    selected_champions = {}
    for side, label, column in (
        ("blue", "Equipe azul", team_columns[0]),
        ("red", "Equipe vermelha", team_columns[1]),
    ):
        with column:
            st.subheader(label)
            selected_team_key = st.selectbox(
                "Equipe",
                team_keys,
                index=0 if side == "blue" else min(1, len(team_keys) - 1),
                format_func=lambda key: team_label(
                    team_by_key[key],
                    team_limit,
                ),
                key=f"{side}_team",
            )
            selected_team_records[side] = team_by_key[selected_team_key]
            selected_teams[side] = selected_team_records[side]["team_name"]
            if (
                selected_team_records[side]["effective_team_games"]
                < team_limit
            ):
                st.warning(
                    "Equipe disponível para consulta, mas atualmente abaixo "
                    "do limite mínimo de amostra. A previsão será bloqueada."
                )
            selected_players[side] = []
            selected_player_records[side] = []
            selected_champions[side] = []
            with st.expander("Jogadores e campeões", expanded=True):
                for position_index, position in enumerate(POSITIONS):
                    roster_rows, using_global_fallback = player_options(
                        bundle,
                        position,
                        selected_teams[side],
                    )
                    player_by_key = {
                        row["key"]: row for row in roster_rows
                    }
                    choices = list(player_by_key)
                    player_limit = float(
                        bundle["sample_limits"]["player_effective_games"]
                    )
                    field_columns = st.columns(2)
                    selected_player_key = field_columns[0].selectbox(
                        f"Jogador {position}",
                        choices,
                        format_func=lambda key, lookup=player_by_key,
                        fallback=using_global_fallback: player_label(
                            lookup[key],
                            player_limit,
                            show_team=fallback,
                        ),
                        key=f"{side}_{position}_player",
                    )
                    selected_player = player_by_key[selected_player_key]
                    selected_player_records[side].append(selected_player)
                    selected_players[side].append(
                        selected_player["player_name"]
                    )
                    selected_champions[side].append(
                        field_columns[1].selectbox(
                            f"Campeão {position}",
                            champions,
                            index=(
                                position_index
                                + (0 if side == "blue" else 5)
                            )
                            % len(champions),
                            key=f"{side}_{position}_champion",
                        )
                    )

    st.subheader("Linha e odds")
    market_columns = st.columns(4)
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
    bet_side = market_columns[3].selectbox(
        "Aposta confirmada",
        ("Nenhuma", "Over", "Under"),
        help="A confirmação registra stake fixa de 1 unidade.",
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
    planned_at = planned_local.astimezone(timezone.utc).isoformat()
    request = {
        "league": league,
        "planned_at": planned_at,
        "map_number": int(map_number),
        "line": float(line),
        "odds_over": float(odds_over) if odds_over > 0 else None,
        "odds_under": float(odds_under) if odds_under > 0 else None,
        "bet_side": bet_side.lower() if bet_side != "Nenhuma" else None,
    }
    for side in ("blue", "red"):
        team_record = selected_team_records[side]
        request[side] = {
            "team_name": selected_teams[side],
            "team_id": team_record.get("team_id"),
            "players": [
                {
                    "player_name": selected_players[side][index],
                    "player_id": selected_player_records[side][index].get(
                        "player_id"
                    ),
                    "position": position,
                    "champion": selected_champions[side][index],
                }
                for index, position in enumerate(POSITIONS)
            ],
        }

    with st.spinner("Calculando distribuição de kills..."):
        result = predict(request, bundle)
        database_url = os.getenv("DATABASE_URL")
        try:
            if "database" in st.secrets:
                database_url = st.secrets["database"].get("url")
        except StreamlitSecretNotFoundError:
            pass
        event_id = save_prediction(request, result, database_url)

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
            f"Intervalo preditivo de 90%: {interval[0]} a {interval[1]} kills."
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
        if result.get("warnings"):
            for warning in result["warnings"]:
                st.warning(warning)
        with st.expander("Distribuição completa"):
            st.dataframe(
                {
                    "kills": list(range(len(result["pmf"]))),
                    "probabilidade": result["pmf"],
                },
                hide_index=True,
                width="stretch",
            )
    if database_url:
        st.info("Evento salvo no histórico permanente.")
    else:
        st.warning(
            "Evento registrado em armazenamento temporário. "
            "Ele pode ser apagado quando o aplicativo reiniciar."
        )
    st.caption(
        f"Evento {event_id}. Modelo {result['model_version']}. "
        f"Dados até {result['data_cutoff']}."
    )

st.markdown(
    '<p class="model-note">Uso informativo. Probabilidade não garante '
    "resultado. Quando houver pouca amostra, o sistema bloqueia a aposta.</p>",
    unsafe_allow_html=True,
)
