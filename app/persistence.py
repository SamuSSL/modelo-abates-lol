from __future__ import annotations

import json
import os
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA = """
CREATE TABLE IF NOT EXISTS prediction_events (
    event_id TEXT PRIMARY KEY,
    prediction_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    status TEXT NOT NULL,
    league TEXT NOT NULL,
    planned_at TEXT NOT NULL,
    blue_team TEXT NOT NULL,
    red_team TEXT NOT NULL,
    map_number INTEGER NOT NULL,
    line REAL NOT NULL,
    bet_side TEXT,
    stake REAL,
    request_json TEXT NOT NULL,
    result_json TEXT NOT NULL
)
"""

BET_DECISION_SCHEMA = """
CREATE TABLE IF NOT EXISTS bet_decisions (
    event_id TEXT PRIMARY KEY,
    prediction_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    decision TEXT NOT NULL CHECK (
        decision IN ('over', 'under', 'no_bet')
    ),
    stake REAL,
    offered_odds REAL,
    FOREIGN KEY (event_id) REFERENCES prediction_events(event_id)
)
"""


def _event_values(
    request: dict[str, Any],
    result: dict[str, Any],
) -> tuple[Any, ...]:
    bet_side = None
    return (
        str(uuid.uuid4()),
        result.get("prediction_id", "blocked"),
        datetime.now(timezone.utc).isoformat(),
        result["status"],
        request["league"],
        request["planned_at"],
        request["blue"]["team_name"],
        request["red"]["team_name"],
        int(request["map_number"]),
        float(request["line"]),
        bet_side,
        1.0 if bet_side else None,
        json.dumps(request, ensure_ascii=False, sort_keys=True),
        json.dumps(result, ensure_ascii=False, sort_keys=True),
    )


def save_prediction(
    request: dict[str, Any],
    result: dict[str, Any],
    database_url: str | None = None,
) -> str:
    database_url = database_url or os.getenv("DATABASE_URL")
    values = _event_values(request, result)
    if database_url and database_url.startswith(
        ("postgres://", "postgresql://")
    ):
        import psycopg

        with psycopg.connect(database_url) as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    INSERT INTO lol_kills.prediction_events VALUES (
                        %s, %s, %s, %s, %s, %s, %s,
                        %s, %s, %s, %s, %s, %s, %s
                    )
                    """,
                    values,
                )
        return values[0]

    local_path = Path(".local") / "predictions.sqlite"
    local_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(local_path) as connection:
        connection.execute(SCHEMA)
        connection.execute(
            """
            INSERT INTO prediction_events VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            )
            """,
            values,
        )
    return values[0]


def save_bet_decision(
    event_id: str,
    prediction_id: str,
    decision: str,
    offered_odds: float | None = None,
    database_url: str | None = None,
) -> str:
    if decision not in {"over", "under", "no_bet"}:
        raise ValueError("Decisão inválida.")
    if decision in {"over", "under"}:
        if offered_odds is None or float(offered_odds) <= 1:
            raise ValueError(
                "Uma aposta confirmada precisa da odd decimal correspondente."
            )
        stake = 1.0
        normalized_odds = float(offered_odds)
    else:
        stake = None
        normalized_odds = None

    values = (
        event_id,
        prediction_id,
        datetime.now(timezone.utc).isoformat(),
        decision,
        stake,
        normalized_odds,
    )
    database_url = database_url or os.getenv("DATABASE_URL")
    if database_url and database_url.startswith(
        ("postgres://", "postgresql://")
    ):
        import psycopg

        with psycopg.connect(database_url) as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    INSERT INTO lol_kills.bet_decisions (
                        event_id,
                        prediction_id,
                        created_at,
                        decision,
                        stake,
                        offered_odds
                    ) VALUES (%s, %s, %s, %s, %s, %s)
                    """,
                    values,
                )
        return event_id

    local_path = Path(".local") / "predictions.sqlite"
    local_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(local_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute(SCHEMA)
        connection.execute(BET_DECISION_SCHEMA)
        connection.execute(
            """
            INSERT INTO bet_decisions (
                event_id,
                prediction_id,
                created_at,
                decision,
                stake,
                offered_odds
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            values,
        )
    return event_id
