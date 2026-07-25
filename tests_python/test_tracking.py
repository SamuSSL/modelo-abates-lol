import pandas as pd

from app.tracking import (
    filter_tracking_data,
    latest_tracking_snapshot,
    regime_label,
)


def tracking_fixture():
    return pd.DataFrame(
        {
            "period": pd.to_datetime(["2025-01-06", "2025-01-13"]),
            "entity_type": ["team", "team"],
            "league_canonical": ["LCK", "LCK"],
            "entity_name": ["Example", "Example"],
            "metric": ["kills_per_minute", "kills_per_minute"],
            "value": [0.5, 0.6],
            "normalized_index": [100.0, 104.0],
            "momentum_percent": [0.0, 4.0],
            "trend_per_week": [0.0, 1.5],
            "volatility_percent": [0.0, 2.0],
            "regime": ["balanced", "hot_accelerating"],
        }
    )


def test_filter_and_latest_snapshot_are_ordered():
    selected = filter_tracking_data(
        tracking_fixture().iloc[::-1],
        "team",
        "LCK",
        "Example",
        "kills_per_minute",
    )
    snapshot = latest_tracking_snapshot(selected)

    assert selected.iloc[0]["period"] < selected.iloc[1]["period"]
    assert snapshot["normalized_index"] == 104.0
    assert snapshot["regime"] == "hot_accelerating"


def test_regime_is_translated_for_reader():
    assert regime_label("hot_accelerating") == "Quente e acelerando"
    assert regime_label("unknown") == "Pouca amostra"
