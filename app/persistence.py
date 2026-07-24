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


def _event_values(
    request: dict[str, Any],
    result: dict[str, Any],
) -> tuple[Any, ...]:
    bet_side = request.get("bet_side")
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
                cursor.execute(SCHEMA)
                cursor.execute(
                    """
                    INSERT INTO prediction_events VALUES (
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
