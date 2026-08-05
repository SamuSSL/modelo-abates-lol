import sqlite3
import sys
import types
from pathlib import Path

import pytest

from app.persistence import (
    load_bet_history,
    save_bet_decision,
    save_prediction,
    save_shadow_predictions,
)


def test_shadow_predictions_and_paper_rules_are_append_only(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    request = {
        "league": "LCK",
        "planned_at": "2026-08-01T12:00:00+00:00",
        "map_number": 1,
        "soft_line": 24.5,
        "team_a": {"team_name": "A"},
        "team_b": {"team_name": "B"},
    }
    result = {"status": "ok", "prediction_id": "prediction"}
    event_id = save_prediction(request, result)
    row = {
        "model_id": "challenger",
        "mode": "market_available",
        "pmf": [0.5, 0.5],
        "paper_rules": [
            {
                "minimum_ev": 0.03,
                "decision": "bet",
                "side": "over",
                "probability": 0.55,
                "odds": 2.0,
                "expected_value": 0.10,
                "stake": 1.0,
            }
        ],
    }
    save_shadow_predictions(event_id, "prediction", [row], bet_blocked=True)
    with sqlite3.connect(".local/predictions.sqlite") as connection:
        shadow_count = connection.execute(
            "SELECT count(*) FROM shadow_predictions"
        ).fetchone()[0]
        paper = connection.execute(
            "SELECT decision, side, stake FROM paper_bet_decisions"
        ).fetchone()
    assert shadow_count == 1
    assert paper == ("blocked", None, 0.0)


def test_prediction_is_appended_without_bet_decision(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    request = {
        "league": "LCK",
        "planned_at": "2026-08-01T12:00:00+00:00",
        "map_number": 1,
        "line": 24.5,
        "blue": {"team_name": "Blue"},
        "red": {"team_name": "Red"},
        "bet_side": "over",
    }
    result = {
        "status": "ok",
        "prediction_id": "prediction",
    }
    event_id = save_prediction(request, result)

    with sqlite3.connect(".local/predictions.sqlite") as connection:
        row = connection.execute(
            "SELECT event_id, stake, bet_side FROM prediction_events"
        ).fetchone()
    assert row == (event_id, None, None)


def test_bet_decision_is_saved_after_prediction(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    request = {
        "league": "LCK",
        "planned_at": "2026-08-01T12:00:00+00:00",
        "map_number": 1,
        "line": 24.5,
        "blue": {"team_name": "Blue"},
        "red": {"team_name": "Red"},
    }
    result = {
        "status": "ok",
        "prediction_id": "prediction",
    }
    event_id = save_prediction(request, result)

    save_bet_decision(
        event_id,
        result["prediction_id"],
        "over",
        1.91,
    )

    with sqlite3.connect(".local/predictions.sqlite") as connection:
        row = connection.execute(
            """
            SELECT event_id, prediction_id, decision, stake, offered_odds
            FROM bet_decisions
            """
        ).fetchone()
    assert row == (event_id, "prediction", "over", 1.0, 1.91)


def test_bet_history_contains_complete_prediction_snapshot(
    monkeypatch,
    tmp_path,
):
    monkeypatch.chdir(tmp_path)
    request = {
        "league": "LCK",
        "planned_at": "2026-08-01T12:00:00+00:00",
        "map_number": 2,
        "line": 24.5,
        "odds_over": 1.91,
        "odds_under": 1.95,
        "moneyline_blue_odds": 1.55,
        "moneyline_red_odds": 2.50,
        "blue": {"team_name": "Blue"},
        "red": {"team_name": "Red"},
    }
    result = {
        "status": "ok",
        "prediction_id": "prediction",
        "mean": 26.1,
        "median": 25,
        "prediction_interval_90": [12, 42],
        "probability_over": 0.58,
        "probability_under": 0.42,
        "fair_odds_over": 1 / 0.58,
        "fair_odds_under": 1 / 0.42,
        "features": {
            "pace": 0.91,
            "p_blue_no_vig": 0.6172839506,
            "p_red_no_vig": 0.3827160494,
            "duration_mean": 31.2,
            "blue_mean": 15.4,
            "red_mean": 10.7,
        },
        "model_version": "directed-test",
        "model_candidate": "joint_ml_quadratic_global",
        "model_status": "experimental_prospective_test",
        "data_cutoff": "2026-07-25",
    }
    event_id = save_prediction(request, result)
    save_bet_decision(event_id, "prediction", "over", 1.91)

    history = load_bet_history()

    assert len(history) == 1
    row = history.iloc[0]
    assert row["event_id"] == event_id
    assert row["map_number"] == 2
    assert row["market_odds_under"] == 1.95
    assert row["moneyline_blue_odds"] == 1.55
    assert row["moneyline_red_odds"] == 2.50
    assert row["moneyline_blue_probability"] == pytest.approx(
        0.6172839506
    )
    assert row["model_probability_over"] == 0.58
    assert row["predicted_mean"] == 26.1
    assert row["predicted_duration_mean"] == 31.2
    assert row["predicted_blue_mean"] == 15.4
    assert row["predicted_red_mean"] == 10.7
    assert row["pace"] == 0.91
    assert row["model_version"] == "directed-test"
    assert row["model_candidate"] == "joint_ml_quadratic_global"
    assert row["model_status"] == "experimental_prospective_test"
    assert row["expected_value"] == pytest.approx(0.58 * 1.91 - 1)


def test_no_bet_decision_has_no_stake_or_odds(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    request = {
        "league": "LCK",
        "planned_at": "2026-08-01T12:00:00+00:00",
        "map_number": 1,
        "line": 24.5,
        "blue": {"team_name": "Blue"},
        "red": {"team_name": "Red"},
    }
    result = {
        "status": "ok",
        "prediction_id": "prediction",
    }
    event_id = save_prediction(request, result)

    save_bet_decision(
        event_id,
        result["prediction_id"],
        "no_bet",
    )

    with sqlite3.connect(".local/predictions.sqlite") as connection:
        row = connection.execute(
            "SELECT decision, stake, offered_odds FROM bet_decisions"
        ).fetchone()
    assert row == ("no_bet", None, None)


def test_bet_history_preserves_active_reference_and_confiometer(
    monkeypatch,
    tmp_path,
):
    monkeypatch.chdir(tmp_path)
    request = {
        "league": "LCK",
        "planned_at": "2026-08-01T12:00:00+00:00",
        "map_number": 1,
        "soft_line": 24.5,
        "soft_odds_over": 2.0,
        "soft_odds_under": 1.9,
        "pinnacle_total_line": 25.5,
        "pinnacle_total_odds_over": 1.95,
        "pinnacle_total_odds_under": 1.95,
        "team_a": {"team_name": "A"},
        "team_b": {"team_name": "B"},
    }
    result = {
        "status": "ok",
        "prediction_id": "prediction",
        "mean": 23.0,
        "probability_over": 0.45,
        "probability_under": 0.55,
        "operational_prediction": {
            "prediction_source": "pinnacle_postdraft",
            "mean": 26.0,
            "median": 25,
            "prediction_interval_90": [12, 42],
            "probability_over": 0.60,
            "probability_under": 0.40,
            "fair_odds_over": 1 / 0.60,
            "fair_odds_under": 1 / 0.40,
        },
        "prediction_source": "pinnacle_postdraft",
        "model_agreement": {
            "status": "opposing_positive_ev",
            "models_agree": False,
            "directional_agreement": False,
            "message": (
                "Modelos divergem. Apostar 0.5u no lado da Pinnacle: Over."
            ),
            "structural_preferred_side": "under",
            "pinnacle_preferred_side": "over",
            "structural_positive_side": "under",
            "pinnacle_positive_side": "over",
            "recommended_side": "over",
            "recommended_stake": 0.5,
            "recommended_model": "pinnacle",
            "recommended_probability": 0.60,
            "recommended_fair_odds": 1 / 0.60,
            "recommended_ev": 0.20,
            "structural_ev_over": -0.10,
            "structural_ev_under": 0.045,
            "pinnacle_ev_over": 0.20,
            "pinnacle_ev_under": -0.24,
        },
    }
    event_id = save_prediction(request, result)
    save_bet_decision(
        event_id,
        "prediction",
        "over",
        2.0,
        stake=0.5,
    )
    row = load_bet_history().iloc[0]
    assert row["prediction_source"] == "pinnacle_postdraft"
    assert row["models_agree"] == False
    assert row["directional_agreement"] == False
    assert row["agreement_message"] == (
        "Modelos divergem. Apostar 0.5u no lado da Pinnacle: Over."
    )
    assert row["confiometer_recommended_side"] == "over"
    assert row["confiometer_recommended_stake"] == 0.5
    assert row["confiometer_recommended_model"] == "pinnacle"
    assert row["decision_probability_source"] == "pinnacle"
    assert row["stake"] == 0.5
    assert row["chosen_probability"] == 0.60
    assert row["expected_value"] == pytest.approx(0.20)
    assert row["predicted_mean"] == 26.0
    assert row["structural_mean"] == 23.0


def test_bet_history_uses_structural_probability_for_structural_recommendation(
    monkeypatch,
    tmp_path,
):
    monkeypatch.chdir(tmp_path)
    request = {
        "league": "LCK",
        "planned_at": "2026-08-01T12:00:00+00:00",
        "map_number": 1,
        "soft_line": 29.5,
        "soft_odds_over": 1.90,
        "soft_odds_under": 1.90,
        "team_a": {"team_name": "A"},
        "team_b": {"team_name": "B"},
    }
    result = {
        "status": "ok",
        "prediction_id": "prediction",
        "mean": 31.0,
        "probability_over": 0.56,
        "probability_under": 0.44,
        "operational_prediction": {
            "prediction_source": "pinnacle_postdraft",
            "mean": 30.0,
            "median": 30,
            "prediction_interval_90": [17, 44],
            "probability_over": 0.52,
            "probability_under": 0.48,
            "fair_odds_over": 1 / 0.52,
            "fair_odds_under": 1 / 0.48,
        },
        "prediction_source": "pinnacle_postdraft",
        "model_agreement": {
            "status": "high_trend",
            "models_agree": False,
            "directional_agreement": True,
            "message": "Confiança alta de tendência. Sinal verde para Over.",
            "recommended_side": "over",
            "recommended_stake": 1.0,
            "recommended_model": "structural",
            "recommended_probability": 0.56,
            "recommended_fair_odds": 1 / 0.56,
            "recommended_ev": 0.064,
        },
    }
    event_id = save_prediction(request, result)
    save_bet_decision(event_id, "prediction", "over", 1.90, stake=1.0)
    row = load_bet_history().iloc[0]
    assert row["decision_probability_source"] == "structural"
    assert row["chosen_probability"] == pytest.approx(0.56)
    assert row["chosen_fair_odds"] == pytest.approx(1 / 0.56)
    assert row["expected_value"] == pytest.approx(0.064)
    assert row["stake"] == 1.0


def test_bet_decision_requires_corresponding_odds(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)

    with pytest.raises(ValueError, match="odd decimal"):
        save_bet_decision("event", "prediction", "under")


@pytest.mark.parametrize("stake", [0, -0.5, 0.25, 0.75, 1.5])
def test_bet_decision_rejects_unsupported_stake(
    monkeypatch,
    tmp_path,
    stake,
):
    monkeypatch.chdir(tmp_path)

    with pytest.raises(ValueError, match="stake precisa ser 0.5u ou 1u"):
        save_bet_decision(
            "event",
            "prediction",
            "under",
            1.90,
            stake=stake,
        )


def test_postgres_uses_isolated_precreated_table(monkeypatch):
    statements = []

    class FakeCursor:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def execute(self, statement, values=None):
            statements.append((statement, values))

    class FakeConnection:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def cursor(self):
            return FakeCursor()

    fake_psycopg = types.SimpleNamespace(
        connect=lambda database_url: FakeConnection()
    )
    monkeypatch.setitem(sys.modules, "psycopg", fake_psycopg)
    request = {
        "league": "LCK",
        "planned_at": "2026-08-01T12:00:00+00:00",
        "map_number": 1,
        "line": 24.5,
        "blue": {"team_name": "Blue"},
        "red": {"team_name": "Red"},
        "bet_side": None,
    }
    result = {
        "status": "ok",
        "prediction_id": "prediction",
    }

    save_prediction(
        request,
        result,
        "postgresql://writer:secret@example.com/postgres",
    )

    assert len(statements) == 1
    assert "INSERT INTO lol_kills.prediction_events" in statements[0][0]
    assert statements[0][1][10:12] == (None, None)


@pytest.mark.parametrize(
    ("decision", "stake", "offered_odds"),
    [
        ("over", 0.5, 1.91),
        ("under", 1.0, 1.87),
        ("no_bet", 1.0, None),
    ],
)
def test_postgres_saves_all_three_decisions_in_separate_table(
    monkeypatch,
    decision,
    stake,
    offered_odds,
):
    statements = []

    class FakeCursor:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def execute(self, statement, values=None):
            statements.append((statement, values))

    class FakeConnection:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def cursor(self):
            return FakeCursor()

    fake_psycopg = types.SimpleNamespace(
        connect=lambda database_url: FakeConnection()
    )
    monkeypatch.setitem(sys.modules, "psycopg", fake_psycopg)

    save_bet_decision(
        "event",
        "prediction",
        decision,
        offered_odds,
        "postgresql://writer:secret@example.com/postgres",
        stake=stake,
    )

    assert len(statements) == 1
    assert "INSERT INTO lol_kills.bet_decisions" in statements[0][0]
    expected_stake = None if decision == "no_bet" else stake
    assert statements[0][1][3:] == (
        decision,
        expected_stake,
        offered_odds,
    )


def test_half_unit_postgres_migration_updates_the_check_constraint():
    migration = Path(
        "sql/004_allow_half_unit_bet_decisions.sql"
    ).read_text(encoding="utf-8")

    assert "stake in (0.5, 1.0)" in migration
    assert "decision = 'no_bet'" in migration
    assert "stake is null" in migration
    assert "offered_odds is null" in migration
