from __future__ import annotations

import json
import os
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pandas as pd


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
                    ON CONFLICT (event_id) DO NOTHING
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
            INSERT OR IGNORE INTO bet_decisions (
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


def _flatten_bet_row(row: tuple[Any, ...]) -> dict[str, Any]:
    (
        event_id,
        prediction_id,
        bet_created_at,
        decision,
        stake,
        offered_odds,
        prediction_created_at,
        league,
        planned_at,
        blue_team,
        red_team,
        map_number,
        line,
        request_json,
        result_json,
    ) = row
    request = json.loads(request_json)
    result = json.loads(result_json)
    interval = result.get("prediction_interval_90") or [None, None]
    chosen_probability = result.get(
        "probability_over" if decision == "over" else "probability_under"
    )
    chosen_fair_odds = result.get(
        "fair_odds_over" if decision == "over" else "fair_odds_under"
    )
    expected_value = (
        float(chosen_probability) * float(offered_odds) - 1
        if chosen_probability is not None and offered_odds is not None
        else None
    )
    return {
        "event_id": event_id,
        "prediction_id": prediction_id,
        "bet_created_at": bet_created_at,
        "prediction_created_at": prediction_created_at,
        "planned_at": planned_at,
        "league": league,
        "blue_team": blue_team,
        "red_team": red_team,
        "map_number": map_number,
        "decision": decision,
        "line": line,
        "offered_odds": offered_odds,
        "stake": stake,
        "market_odds_over": request.get("odds_over"),
        "market_odds_under": request.get("odds_under"),
        "model_probability_over": result.get("probability_over"),
        "model_probability_under": result.get("probability_under"),
        "chosen_probability": chosen_probability,
        "fair_odds_over": result.get("fair_odds_over"),
        "fair_odds_under": result.get("fair_odds_under"),
        "chosen_fair_odds": chosen_fair_odds,
        "expected_value": expected_value,
        "predicted_mean": result.get("mean"),
        "predicted_median": result.get("median"),
        "prediction_interval_90_low": interval[0],
        "prediction_interval_90_high": interval[1],
        "pace": (result.get("features") or {}).get("pace"),
        "model_version": result.get("model_version"),
        "data_cutoff": result.get("data_cutoff"),
    }


def load_bet_history(
    database_url: str | None = None,
) -> pd.DataFrame:
    database_url = database_url or os.getenv("DATABASE_URL")
    query = """
        SELECT
            decision.event_id,
            decision.prediction_id,
            decision.created_at,
            decision.decision,
            decision.stake,
            decision.offered_odds,
            prediction.created_at,
            prediction.league,
            prediction.planned_at,
            prediction.blue_team,
            prediction.red_team,
            prediction.map_number,
            prediction.line,
            prediction.request_json,
            prediction.result_json
        FROM {prediction_table} AS prediction
        INNER JOIN {decision_table} AS decision
            ON decision.event_id = prediction.event_id
        WHERE decision.decision IN ('over', 'under')
        ORDER BY decision.created_at DESC
    """
    if database_url and database_url.startswith(
        ("postgres://", "postgresql://")
    ):
        import psycopg

        with psycopg.connect(database_url) as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    query.format(
                        prediction_table="lol_kills.prediction_events",
                        decision_table="lol_kills.bet_decisions",
                    )
                )
                rows = cursor.fetchall()
    else:
        local_path = Path(".local") / "predictions.sqlite"
        if not local_path.exists():
            return pd.DataFrame()
        with sqlite3.connect(local_path) as connection:
            connection.execute(SCHEMA)
            connection.execute(BET_DECISION_SCHEMA)
            rows = connection.execute(
                query.format(
                    prediction_table="prediction_events",
                    decision_table="bet_decisions",
                )
            ).fetchall()
    return pd.DataFrame([_flatten_bet_row(row) for row in rows])
