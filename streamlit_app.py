from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import streamlit as st
from streamlit.errors import StreamlitSecretNotFoundError

from app.lolkills_inference import POSITIONS, load_bundle, predict
from app.persistence import save_prediction


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

BUNDLE_PATH = Path("app_data/model_bundle.json")
if not BUNDLE_PATH.exists():
    st.error("O bundle do modelo não está disponível. O deploy está incompleto.")
    st.stop()


@st.cache_resource
def get_bundle():
    return load_bundle(BUNDLE_PATH)


bundle = get_bundle()
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

with st.form("prediction_form"):
    st.subheader("Partida")
    match_columns = st.columns(4)
    league_options = bundle["model"]["league_levels"]
    eligible_league_counts = {
        league_name: sum(
            1
            for row in bundle["teams"]
            if row.get("league_canonical") == league_name
            and row["effective_team_games"]
            >= bundle["sample_limits"]["team_effective_games"]
        )
        for league_name in league_options
    }
    default_league_index = next(
        (
            index
            for index, league_name in enumerate(league_options)
            if eligible_league_counts[league_name] >= 2
        ),
        0,
    )
    league = match_columns[0].selectbox(
        "Liga",
        league_options,
        index=default_league_index,
    )
    team_names = sorted(
        {
            row["team_name"]
            for row in bundle["teams"]
            if row.get("league_canonical") == league
            and row["effective_team_games"]
            >= bundle["sample_limits"]["team_effective_games"]
        }
    )
    if len(team_names) < 2:
        st.error("A liga não possui duas equipes elegíveis no snapshot atual.")
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
    selected_players = {}
    selected_champions = {}
    for side, label, column in (
        ("blue", "Equipe azul", team_columns[0]),
        ("red", "Equipe vermelha", team_columns[1]),
    ):
        with column:
            st.subheader(label)
            selected_teams[side] = st.selectbox(
                "Equipe",
                team_names,
                index=0 if side == "blue" else min(1, len(team_names) - 1),
                key=f"{side}_team",
            )
            selected_players[side] = []
            selected_champions[side] = []
            with st.expander("Jogadores e campeões", expanded=True):
                for position_index, position in enumerate(POSITIONS):
                    team_choices = sorted(
                        {
                            row["player_name"]
                            for row in player_rows
                            if row["position"] == position
                            and row.get("team_name") == selected_teams[side]
                            and row["effective_player_games"]
                            >= bundle["sample_limits"]["player_effective_games"]
                        }
                    )
                    choices = team_choices or sorted(
                        {
                            row["player_name"]
                            for row in player_rows
                            if row["position"] == position
                            and row["effective_player_games"]
                            >= bundle["sample_limits"]["player_effective_games"]
                        }
                    )
                    field_columns = st.columns(2)
                    selected_players[side].append(
                        field_columns[0].selectbox(
                            f"Jogador {position}",
                            choices,
                            key=f"{side}_{position}_player",
                        )
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
    submitted = st.form_submit_button(
        "Calcular previsão",
        type="primary",
        use_container_width=True,
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
        team_record = next(
            row
            for row in bundle["teams"]
            if row["team_name"] == selected_teams[side]
            and row.get("league_canonical") == league
        )
        request[side] = {
            "team_name": selected_teams[side],
            "team_id": team_record.get("team_id"),
            "players": [
                {
                    "player_name": selected_players[side][index],
                    "player_id": resolve_player_record(
                        selected_players[side][index],
                        position,
                        selected_teams[side],
                    ).get("player_id"),
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
        st.success("Previsão calculada e salva.")
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
                use_container_width=True,
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
