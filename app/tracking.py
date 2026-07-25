from __future__ import annotations

from pathlib import Path

import altair as alt
import pandas as pd
import streamlit as st


METRIC_LABELS = {
    "total_kills": "Total de kills por mapa",
    "total_kills_per_minute": "Kills totais por minuto",
    "game_length_minutes": "Duração do mapa",
    "kills_per_minute": "Ataque (kills por minuto)",
    "deaths_per_minute": "Exposição defensiva (deaths por minuto)",
    "combined_kills_per_minute": "Ritmo de combate (kills combinadas por minuto)",
    "rating_attack_league": "Rating de ataque contra a liga",
    "rating_defense_league": "Rating de defesa contra a liga",
    "rating_attack_global": "Rating de ataque global",
    "rating_defense_global": "Rating de defesa global",
    "aggression_ahead_league": "Agressividade quando está à frente",
    "aggression_behind_league": "Agressividade quando está atrás",
    "snowball_index_league": "Índice de snowball",
}

REGIME_LABELS = {
    "balanced": "Equilibrado",
    "hot_accelerating": "Quente e acelerando",
    "hot_cooling": "Quente, desacelerando",
    "cold_deteriorating": "Frio e enfraquecendo",
    "cold_recovering": "Frio, recuperando",
    "insufficient": "Pouca amostra",
}


@st.cache_data
def load_tracking_data(path: str | Path) -> pd.DataFrame:
    frame = pd.read_csv(path, parse_dates=["period"])
    numeric_columns = [
        "value",
        "short_level",
        "long_level",
        "normalized_index",
        "momentum_percent",
        "trend_per_week",
        "volatility_percent",
        "observations",
    ]
    for column in numeric_columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
    return frame


def filter_tracking_data(
    frame: pd.DataFrame,
    entity_type: str,
    league: str,
    entity_name: str,
    metric: str,
) -> pd.DataFrame:
    selected = frame.loc[
        (frame["entity_type"] == entity_type)
        & (frame["league_canonical"] == league)
        & (frame["entity_name"] == entity_name)
        & (frame["metric"] == metric)
    ].copy()
    return selected.sort_values("period").reset_index(drop=True)


def latest_tracking_snapshot(frame: pd.DataFrame) -> dict:
    valid = frame.dropna(
        subset=[
            "normalized_index",
            "momentum_percent",
            "trend_per_week",
        ]
    )
    if valid.empty:
        return {
            "normalized_index": None,
            "momentum_percent": None,
            "trend_per_week": None,
            "volatility_percent": None,
            "regime": "insufficient",
        }
    return valid.iloc[-1].to_dict()


def regime_label(regime: str) -> str:
    return REGIME_LABELS.get(regime, "Pouca amostra")


def _normalized_chart(frame: pd.DataFrame) -> alt.LayerChart:
    base = alt.Chart(frame).encode(
        x=alt.X("period:T", title="Semana"),
        tooltip=[
            alt.Tooltip("period:T", title="Semana"),
            alt.Tooltip(
                "normalized_index:Q",
                title="Índice",
                format=".1f",
            ),
            alt.Tooltip("value:Q", title="Valor observado", format=".3f"),
            alt.Tooltip("regime:N", title="Regime"),
        ],
    )
    line = base.mark_line(point=False).encode(
        y=alt.Y(
            "normalized_index:Q",
            title="Índice normalizado (100 = padrão recente)",
            scale=alt.Scale(zero=False),
        )
    )
    baseline = alt.Chart(
        pd.DataFrame({"baseline": [100]})
    ).mark_rule(
        strokeDash=[5, 4],
        color="#8a94a6",
    ).encode(y="baseline:Q")
    return (line + baseline).properties(height=340)


def _indicator_chart(
    frame: pd.DataFrame,
    column: str,
    title: str,
) -> alt.LayerChart:
    line = (
        alt.Chart(frame)
        .mark_line()
        .encode(
            x=alt.X("period:T", title="Semana"),
            y=alt.Y(
                f"{column}:Q",
                title=title,
                scale=alt.Scale(zero=False),
            ),
            tooltip=[
                alt.Tooltip("period:T", title="Semana"),
                alt.Tooltip(f"{column}:Q", title=title, format=".2f"),
            ],
        )
    )
    baseline = alt.Chart(
        pd.DataFrame({"baseline": [0]})
    ).mark_rule(
        strokeDash=[4, 4],
        color="#8a94a6",
    ).encode(y="baseline:Q")
    return (line + baseline).properties(height=220)


def render_tracking_page(frame: pd.DataFrame) -> None:
    st.title("Tracking temporal")
    st.write(
        "O índice compara o nível recente com o padrão mais longo. "
        "100 significa que ambos estão alinhados; acima de 100 indica "
        "aquecimento e abaixo de 100 indica esfriamento."
    )

    entity_label = st.radio(
        "Acompanhar",
        ("Liga", "Equipe"),
        horizontal=True,
    )
    entity_type = "league" if entity_label == "Liga" else "team"
    leagues = sorted(
        frame.loc[frame["entity_type"] == entity_type, "league_canonical"]
        .dropna()
        .unique()
        .tolist()
    )
    league = st.selectbox("Liga", leagues, key="tracking_league")
    eligible = frame.loc[
        (frame["entity_type"] == entity_type)
        & (frame["league_canonical"] == league)
    ]
    entities = sorted(eligible["entity_name"].dropna().unique().tolist())
    entity_recency = (
        eligible.groupby("entity_name", as_index=False)
        .agg(latest_period=("period", "max"), points=("period", "count"))
        .sort_values(
            ["latest_period", "points", "entity_name"],
            ascending=[False, False, True],
        )
    )
    default_entity = entity_recency.iloc[0]["entity_name"]
    entity_name = (
        league
        if entity_type == "league"
        else st.selectbox(
            "Equipe",
            entities,
            index=entities.index(default_entity),
            key="tracking_team",
        )
    )
    metrics = sorted(
        eligible.loc[
            eligible["entity_name"] == entity_name,
            "metric",
        ]
        .dropna()
        .unique()
        .tolist(),
        key=lambda metric: METRIC_LABELS.get(metric, metric),
    )
    preferred_metric = (
        "total_kills"
        if entity_type == "league"
        else "combined_kills_per_minute"
    )
    metric = st.selectbox(
        "Indicador",
        metrics,
        index=(
            metrics.index(preferred_metric)
            if preferred_metric in metrics
            else 0
        ),
        format_func=lambda item: METRIC_LABELS.get(item, item),
        key="tracking_metric",
    )
    selected = filter_tracking_data(
        frame,
        entity_type,
        league,
        entity_name,
        metric,
    )
    snapshot = latest_tracking_snapshot(selected)

    summary_columns = st.columns(4)
    summary_columns[0].metric(
        "Índice normalizado",
        (
            f"{snapshot['normalized_index']:.1f}"
            if snapshot["normalized_index"] is not None
            else "Sem dado"
        ),
    )
    summary_columns[1].metric(
        "Momentum",
        (
            f"{snapshot['momentum_percent']:+.1f}%"
            if snapshot["momentum_percent"] is not None
            else "Sem dado"
        ),
    )
    summary_columns[2].metric(
        "Tendência semanal",
        (
            f"{snapshot['trend_per_week']:+.2f}%"
            if snapshot["trend_per_week"] is not None
            else "Sem dado"
        ),
    )
    volatility = snapshot.get("volatility_percent")
    summary_columns[3].metric(
        "Volatilidade",
        f"{volatility:.2f}%" if pd.notna(volatility) else "Sem dado",
    )
    st.caption(
        f"Regime atual: {regime_label(str(snapshot['regime']))}. "
        "O regime descreve direção e velocidade, não uma previsão garantida."
    )

    st.altair_chart(_normalized_chart(selected), width="stretch")
    indicator_columns = st.columns(2)
    indicator_columns[0].altair_chart(
        _indicator_chart(
            selected,
            "momentum_percent",
            "Momentum (%)",
        ),
        width="stretch",
    )
    indicator_columns[1].altair_chart(
        _indicator_chart(
            selected,
            "trend_per_week",
            "Tendência por semana (%)",
        ),
        width="stretch",
    )

    with st.expander("Últimas semanas"):
        recent = selected.tail(12).loc[
            :,
            [
                "period",
                "value",
                "normalized_index",
                "momentum_percent",
                "trend_per_week",
                "volatility_percent",
                "regime",
            ],
        ].copy()
        recent["regime"] = recent["regime"].map(regime_label)
        st.dataframe(
            recent.rename(
                columns={
                    "period": "Semana",
                    "value": "Valor",
                    "normalized_index": "Índice",
                    "momentum_percent": "Momentum (%)",
                    "trend_per_week": "Tendência semanal (%)",
                    "volatility_percent": "Volatilidade (%)",
                    "regime": "Regime",
                }
            ),
            hide_index=True,
            width="stretch",
        )
