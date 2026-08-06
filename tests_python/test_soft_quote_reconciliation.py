import csv
import importlib.util
import json
import sqlite3
from pathlib import Path

import pytest

from app.persistence import QUOTE_OUTCOME_SCHEMA, SOFT_QUOTE_SCHEMA


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "121_reconcile_soft_quotes.py"
SPEC = importlib.util.spec_from_file_location("soft_quote_reconciliation", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def _insert_quote(connection: sqlite3.Connection, quote_id: str, line: float) -> None:
    connection.execute(
        """
        INSERT INTO soft_quote_observations VALUES (
            ?, NULL, NULL, '2026-08-05T12:00:00+00:00', 'Soft', 'game-1',
            'LCK', '2026-08-05T13:00:00+00:00', 'A', 'B', 1, 'first_seen',
            ?, 2.10, 1.80, 0, NULL, NULL, NULL, 'manual', '{}'
        )
        """,
        (quote_id, line),
    )


def test_reconciliation_requires_exact_game_and_line(tmp_path, monkeypatch):
    database = tmp_path / "predictions.sqlite"
    export = tmp_path / "pinnacle.csv"
    with export.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "gameid", "line", "odds_over", "odds_under", "final_pinnacle_time"
            ],
        )
        writer.writeheader()
        writer.writerow(
            {
                "gameid": "game-1",
                "line": 25.5,
                "odds_over": 1.90,
                "odds_under": 1.95,
                "final_pinnacle_time": "2026-08-05T12:55:00Z",
            }
        )
    with sqlite3.connect(database) as connection:
        connection.execute(SOFT_QUOTE_SCHEMA)
        connection.execute(QUOTE_OUTCOME_SCHEMA)
        _insert_quote(connection, "matched", 25.5)
        _insert_quote(connection, "wrong-line", 26.5)
        connection.execute(
            """
            INSERT INTO quote_outcomes VALUES (
                'matched', '2026-08-05T12:01:00Z', 'accepted', 'over',
                2.10, 0.10, 2.10, 0.10, NULL, NULL, NULL, NULL, NULL, NULL,
                NULL, NULL, '{}'
            )
            """
        )
    monkeypatch.setattr(MODULE, "PINNACLE_EXPORT", export)

    rows = MODULE.reconcile(database)

    assert [row["matched"] for row in rows] == [True, False]
    with sqlite3.connect(database) as connection:
        outcome = connection.execute(
            "SELECT * FROM quote_outcomes WHERE quote_id = 'matched'"
        ).fetchone()
        columns = [column[0] for column in connection.execute(
            "SELECT * FROM quote_outcomes LIMIT 0"
        ).description]
    saved = dict(zip(columns, outcome))
    assert saved["execution_status"] == "accepted"
    assert saved["final_pinnacle_line"] == 25.5
    assert saved["clv"] == pytest.approx(2.10 / 1.90 - 1)
    assert json.loads(saved["payload_json"])["pinnacle_reconciliation"]["gameid"] == "game-1"
