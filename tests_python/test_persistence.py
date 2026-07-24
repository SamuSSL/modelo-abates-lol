import sqlite3

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
