import sqlite3
import sys
import types

import pytest

from app.persistence import save_bet_decision, save_prediction


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


def test_bet_decision_requires_corresponding_odds(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)

    with pytest.raises(ValueError, match="odd decimal"):
        save_bet_decision("event", "prediction", "under")


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


def test_postgres_saves_decision_in_separate_table(monkeypatch):
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
        "under",
        1.87,
        "postgresql://writer:secret@example.com/postgres",
    )

    assert len(statements) == 1
    assert "INSERT INTO lol_kills.bet_decisions" in statements[0][0]
    assert statements[0][1][3:] == ("under", 1.0, 1.87)
