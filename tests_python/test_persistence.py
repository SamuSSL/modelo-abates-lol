import sqlite3
import sys
import types

from app.persistence import save_prediction


def test_prediction_is_appended(monkeypatch, tmp_path):
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
    assert row == (event_id, 1.0, "over")


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
