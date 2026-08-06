from __future__ import annotations

import json
import hashlib
import math
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

SHADOW_PREDICTION_SCHEMA = """
CREATE TABLE IF NOT EXISTS shadow_predictions (
    shadow_id TEXT PRIMARY KEY,
    event_id TEXT NOT NULL,
    prediction_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    model_id TEXT NOT NULL,
    mode TEXT NOT NULL,
    shadow_json TEXT NOT NULL,
    FOREIGN KEY (event_id) REFERENCES prediction_events(event_id)
)
"""

PAPER_DECISION_SCHEMA = """
CREATE TABLE IF NOT EXISTS paper_bet_decisions (
    paper_id TEXT PRIMARY KEY,
    shadow_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    prediction_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    model_id TEXT NOT NULL,
    minimum_ev REAL NOT NULL,
    decision TEXT NOT NULL CHECK (decision IN ('bet', 'pass', 'blocked')),
    side TEXT,
    probability REAL,
    odds REAL,
    expected_value REAL NOT NULL,
    stake REAL NOT NULL,
    FOREIGN KEY (shadow_id) REFERENCES shadow_predictions(shadow_id),
    FOREIGN KEY (event_id) REFERENCES prediction_events(event_id)
)
"""

SOFT_QUOTE_SCHEMA = """
CREATE TABLE IF NOT EXISTS soft_quote_observations (
    quote_id TEXT PRIMARY KEY,
    event_id TEXT,
    prediction_id TEXT,
    observed_at TEXT NOT NULL,
    bookmaker TEXT NOT NULL,
    gameid TEXT,
    league TEXT NOT NULL,
    planned_at TEXT NOT NULL,
    blue_team TEXT NOT NULL,
    red_team TEXT NOT NULL,
    map_number INTEGER NOT NULL,
    quote_stage TEXT NOT NULL CHECK (quote_stage IN ('first_seen', 'update')),
    line REAL NOT NULL,
    odds_over REAL NOT NULL,
    odds_under REAL NOT NULL,
    pinnacle_available INTEGER NOT NULL,
    pinnacle_line REAL,
    pinnacle_odds_over REAL,
    pinnacle_odds_under REAL,
    quote_source TEXT NOT NULL,
    payload_json TEXT NOT NULL
)
"""

PINNACLE_FORECAST_SCHEMA = """
CREATE TABLE IF NOT EXISTS pinnacle_forecasts (
    forecast_id TEXT PRIMARY KEY,
    quote_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    model_id TEXT NOT NULL,
    model_status TEXT NOT NULL,
    target TEXT NOT NULL,
    predicted_last_mu REAL,
    predicted_last_mu_low REAL,
    predicted_last_mu_high REAL,
    probability_over REAL,
    probability_under REAL,
    conservative_ev_over REAL,
    conservative_ev_under REAL,
    recommended_side TEXT,
    action TEXT NOT NULL,
    stake REAL NOT NULL,
    payload_json TEXT NOT NULL,
    FOREIGN KEY (quote_id) REFERENCES soft_quote_observations(quote_id)
)
"""

QUOTE_OUTCOME_SCHEMA = """
CREATE TABLE IF NOT EXISTS quote_outcomes (
    quote_id TEXT PRIMARY KEY,
    updated_at TEXT NOT NULL,
    execution_status TEXT NOT NULL CHECK (
        execution_status IN (
            'pending', 'not_attempted', 'accepted', 'rejected',
            'win', 'loss', 'void'
        )
    ),
    executed_side TEXT CHECK (executed_side IN ('over', 'under')),
    requested_odds REAL,
    requested_stake REAL,
    accepted_odds REAL,
    accepted_stake REAL,
    settled_at TEXT,
    profit REAL,
    final_pinnacle_time TEXT,
    final_pinnacle_line REAL,
    final_pinnacle_odds_over REAL,
    final_pinnacle_odds_under REAL,
    clv REAL,
    notes TEXT,
    payload_json TEXT NOT NULL,
    FOREIGN KEY (quote_id) REFERENCES soft_quote_observations(quote_id)
)
"""


def _event_values(
    request: dict[str, Any],
    result: dict[str, Any],
) -> tuple[Any, ...]:
    bet_side = None
    team_a = request.get("team_a") or request.get("blue") or {}
    team_b = request.get("team_b") or request.get("red") or {}
    line = request.get("soft_line", request.get("line"))
    return (
        str(uuid.uuid4()),
        result.get("prediction_id", "blocked"),
        datetime.now(timezone.utc).isoformat(),
        result["status"],
        request["league"],
        request["planned_at"],
        team_a["team_name"],
        team_b["team_name"],
        int(request["map_number"]),
        float(line),
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


def save_shadow_predictions(
    event_id: str,
    prediction_id: str,
    shadow_rows: list[dict[str, Any]],
    bet_blocked: bool = False,
    database_url: str | None = None,
) -> list[str]:
    created_at = datetime.now(timezone.utc).isoformat()
    shadow_values: list[tuple[Any, ...]] = []
    paper_values: list[tuple[Any, ...]] = []
    for row in shadow_rows:
        shadow_id = str(uuid.uuid4())
        shadow_values.append(
            (
                shadow_id,
                event_id,
                prediction_id,
                created_at,
                row["model_id"],
                row["mode"],
                json.dumps(row, ensure_ascii=False, sort_keys=True),
            )
        )
        for rule in row.get("paper_rules") or []:
            decision = "blocked" if bet_blocked else rule["decision"]
            paper_values.append(
                (
                    str(uuid.uuid4()),
                    shadow_id,
                    event_id,
                    prediction_id,
                    created_at,
                    row["model_id"],
                    float(rule["minimum_ev"]),
                    decision,
                    None if bet_blocked else rule.get("side"),
                    None if bet_blocked else rule.get("probability"),
                    None if bet_blocked else rule.get("odds"),
                    float(rule["expected_value"]),
                    0.0 if bet_blocked else float(rule.get("stake", 0.0)),
                )
            )
    database_url = database_url or os.getenv("DATABASE_URL")
    if database_url and database_url.startswith(("postgres://", "postgresql://")):
        import psycopg

        with psycopg.connect(database_url) as connection:
            with connection.cursor() as cursor:
                cursor.executemany(
                    """
                    INSERT INTO lol_kills.shadow_predictions VALUES (
                        %s, %s, %s, %s, %s, %s, %s
                    )
                    """,
                    shadow_values,
                )
                cursor.executemany(
                    """
                    INSERT INTO lol_kills.paper_bet_decisions VALUES (
                        %s, %s, %s, %s, %s, %s, %s,
                        %s, %s, %s, %s, %s, %s
                    )
                    """,
                    paper_values,
                )
        return [row[0] for row in shadow_values]

    local_path = Path(".local") / "predictions.sqlite"
    local_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(local_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute(SCHEMA)
        connection.execute(SHADOW_PREDICTION_SCHEMA)
        connection.execute(PAPER_DECISION_SCHEMA)
        connection.executemany(
            "INSERT INTO shadow_predictions VALUES (?, ?, ?, ?, ?, ?, ?)",
            shadow_values,
        )
        connection.executemany(
            """
            INSERT INTO paper_bet_decisions VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            )
            """,
            paper_values,
        )
    return [row[0] for row in shadow_values]


def save_bet_decision(
    event_id: str,
    prediction_id: str,
    decision: str,
    offered_odds: float | None = None,
    database_url: str | None = None,
    *,
    stake: float = 1.0,
) -> str:
    if decision not in {"over", "under", "no_bet"}:
        raise ValueError("Decisão inválida.")
    if decision in {"over", "under"}:
        if offered_odds is None or float(offered_odds) <= 1:
            raise ValueError(
                "Uma aposta confirmada precisa da odd decimal correspondente."
            )
        if not math.isfinite(float(stake)) or float(stake) not in {0.5, 1.0}:
            raise ValueError("A stake precisa ser 0.5u ou 1u.")
        normalized_stake = float(stake)
        normalized_odds = float(offered_odds)
    else:
        normalized_stake = None
        normalized_odds = None

    values = (
        event_id,
        prediction_id,
        datetime.now(timezone.utc).isoformat(),
        decision,
        normalized_stake,
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
    operational = result.get("operational_prediction") or result
    agreement = result.get("model_agreement") or {}
    interval = operational.get("prediction_interval_90") or [None, None]
    recommendation_applied = (
        decision == agreement.get("recommended_side")
        and agreement.get("recommended_probability") is not None
    )
    if recommendation_applied:
        chosen_probability = agreement.get("recommended_probability")
        chosen_fair_odds = agreement.get("recommended_fair_odds")
        decision_probability_source = agreement.get("recommended_model")
    else:
        chosen_probability = operational.get(
            "probability_over" if decision == "over" else "probability_under"
        )
        chosen_fair_odds = operational.get(
            "fair_odds_over" if decision == "over" else "fair_odds_under"
        )
        decision_probability_source = operational.get("prediction_source")
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
        "market_odds_over": request.get(
            "soft_odds_over", request.get("odds_over")
        ),
        "market_odds_under": request.get(
            "soft_odds_under", request.get("odds_under")
        ),
        "pinnacle_total_line": request.get("pinnacle_total_line"),
        "pinnacle_total_odds_over": request.get(
            "pinnacle_total_odds_over"
        ),
        "pinnacle_total_odds_under": request.get(
            "pinnacle_total_odds_under"
        ),
        "moneyline_blue_odds": request.get(
            "moneyline_team_a_odds", request.get("moneyline_blue_odds")
        ),
        "moneyline_red_odds": request.get(
            "moneyline_team_b_odds", request.get("moneyline_red_odds")
        ),
        "moneyline_blue_probability": (
            result.get("features") or {}
        ).get("p_blue_no_vig"),
        "moneyline_red_probability": (
            result.get("features") or {}
        ).get("p_red_no_vig"),
        "model_probability_over": result.get("probability_over"),
        "model_probability_under": result.get("probability_under"),
        "reference_probability_over": operational.get("probability_over"),
        "reference_probability_under": operational.get("probability_under"),
        "chosen_probability": chosen_probability,
        "fair_odds_over": operational.get("fair_odds_over"),
        "fair_odds_under": operational.get("fair_odds_under"),
        "chosen_fair_odds": chosen_fair_odds,
        "decision_probability_source": decision_probability_source,
        "expected_value": expected_value,
        "prediction_source": result.get(
            "prediction_source",
            operational.get("prediction_source", "structural_legacy"),
        ),
        "models_agree": agreement.get("models_agree"),
        "directional_agreement": agreement.get(
            "directional_agreement"
        ),
        "agreement_status": agreement.get("status"),
        "agreement_message": agreement.get("message"),
        "structural_preferred_side": agreement.get(
            "structural_preferred_side"
        ),
        "pinnacle_preferred_side": agreement.get(
            "pinnacle_preferred_side"
        ),
        "structural_positive_side": agreement.get(
            "structural_positive_side"
        ),
        "pinnacle_positive_side": agreement.get(
            "pinnacle_positive_side"
        ),
        "structural_signal_side": agreement.get("structural_signal_side"),
        "pinnacle_signal_side": agreement.get("pinnacle_signal_side"),
        "soft_no_vig_probability_over": agreement.get(
            "soft_no_vig_probability_over"
        ),
        "structural_probability_edge": agreement.get(
            "structural_probability_edge"
        ),
        "pinnacle_probability_edge": agreement.get(
            "pinnacle_probability_edge"
        ),
        "mean_disagreement_kills": agreement.get(
            "mean_disagreement_kills"
        ),
        "extreme_mean_disagreement": agreement.get(
            "extreme_mean_disagreement"
        ),
        "confiometer_recommended_side": agreement.get(
            "recommended_side"
        ),
        "confiometer_recommended_stake": agreement.get(
            "recommended_stake"
        ),
        "confiometer_recommended_model": agreement.get(
            "recommended_model"
        ),
        "confiometer_recommended_probability": agreement.get(
            "recommended_probability"
        ),
        "confiometer_recommended_fair_odds": agreement.get(
            "recommended_fair_odds"
        ),
        "confiometer_recommended_ev": agreement.get("recommended_ev"),
        "structural_ev_over": agreement.get("structural_ev_over"),
        "structural_ev_under": agreement.get("structural_ev_under"),
        "pinnacle_ev_over": agreement.get("pinnacle_ev_over"),
        "pinnacle_ev_under": agreement.get("pinnacle_ev_under"),
        "predicted_mean": operational.get("mean"),
        "structural_mean": result.get("mean"),
        "predicted_median": operational.get("median"),
        "predicted_duration_mean": (
            result.get("features") or {}
        ).get("duration_mean"),
        "predicted_blue_mean": (
            result.get("features") or {}
        ).get("blue_mean"),
        "predicted_red_mean": (
            result.get("features") or {}
        ).get("red_mean"),
        "prediction_interval_90_low": interval[0],
        "prediction_interval_90_high": interval[1],
        "pace": (result.get("features") or {}).get("pace"),
        "model_version": result.get("model_version"),
        "model_candidate": result.get("model_candidate"),
        "model_status": result.get("model_status"),
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


def _validate_soft_quote(quote: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(quote)
    bookmaker = str(normalized.get("bookmaker") or "").strip()
    if not bookmaker:
        raise ValueError("A casa soft precisa ser informada.")
    stage = str(normalized.get("quote_stage") or "first_seen")
    if stage not in {"first_seen", "update"}:
        raise ValueError("quote_stage precisa ser first_seen ou update.")
    observed_raw = normalized.get("observed_at") or datetime.now(
        timezone.utc
    ).isoformat()
    observed_at = datetime.fromisoformat(
        str(observed_raw).replace("Z", "+00:00")
    )
    if observed_at.tzinfo is None:
        raise ValueError("observed_at precisa informar o fuso.")
    planned_at = datetime.fromisoformat(
        str(normalized["planned_at"]).replace("Z", "+00:00")
    )
    if planned_at.tzinfo is None:
        raise ValueError("planned_at precisa informar o fuso.")
    line = float(normalized["soft_line"])
    odds_over = float(normalized["soft_odds_over"])
    odds_under = float(normalized["soft_odds_under"])
    if (
        not math.isfinite(line)
        or line < 0.5
        or not math.isclose(line % 1, 0.5, abs_tol=1e-12)
        or not math.isfinite(odds_over)
        or not math.isfinite(odds_under)
        or odds_over <= 1
        or odds_under <= 1
    ):
        raise ValueError("A cotação soft precisa de linha .5 e duas odds válidas.")
    pinnacle_available = bool(normalized.get("pinnacle_input_available"))
    pinnacle_values = (
        normalized.get("pinnacle_total_line"),
        normalized.get("pinnacle_total_odds_over"),
        normalized.get("pinnacle_total_odds_under"),
    )
    if pinnacle_available:
        if any(value is None for value in pinnacle_values):
            raise ValueError("Pinnacle disponível exige linha e duas odds.")
        pinnacle_line = float(pinnacle_values[0])
        pinnacle_over = float(pinnacle_values[1])
        pinnacle_under = float(pinnacle_values[2])
        if (
            pinnacle_over <= 1
            or pinnacle_under <= 1
            or not math.isclose(pinnacle_line % 1, 0.5, abs_tol=1e-12)
        ):
            raise ValueError("A cotação Pinnacle está inválida.")
    normalized.update(
        {
            "bookmaker": bookmaker,
            "quote_stage": stage,
            "observed_at": observed_at.astimezone(timezone.utc).isoformat(),
            "planned_at": planned_at.astimezone(timezone.utc).isoformat(),
            "soft_line": line,
            "soft_odds_over": odds_over,
            "soft_odds_under": odds_under,
            "pinnacle_input_available": pinnacle_available,
            "quote_source": str(normalized.get("quote_source") or "manual"),
        }
    )
    return normalized


def _soft_quote_values(
    quote: dict[str, Any],
    event_id: str | None,
    prediction_id: str | None,
) -> tuple[Any, ...]:
    normalized = _validate_soft_quote(quote)
    team_a = normalized.get("team_a") or normalized.get("blue") or {}
    team_b = normalized.get("team_b") or normalized.get("red") or {}
    identity = "|".join(
        str(value)
        for value in (
            normalized["observed_at"],
            normalized["bookmaker"],
            normalized.get("gameid"),
            normalized["league"],
            normalized["map_number"],
            normalized["quote_stage"],
            normalized["soft_line"],
            normalized["soft_odds_over"],
            normalized["soft_odds_under"],
        )
    )
    quote_id = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    return (
        quote_id,
        event_id,
        prediction_id,
        normalized["observed_at"],
        normalized["bookmaker"],
        normalized.get("gameid"),
        normalized["league"],
        normalized["planned_at"],
        str(team_a.get("team_name") or ""),
        str(team_b.get("team_name") or ""),
        int(normalized["map_number"]),
        normalized["quote_stage"],
        normalized["soft_line"],
        normalized["soft_odds_over"],
        normalized["soft_odds_under"],
        int(normalized["pinnacle_input_available"]),
        normalized.get("pinnacle_total_line"),
        normalized.get("pinnacle_total_odds_over"),
        normalized.get("pinnacle_total_odds_under"),
        normalized["quote_source"],
        json.dumps(normalized, ensure_ascii=False, sort_keys=True),
    )


def save_soft_quote_observation(
    quote: dict[str, Any],
    event_id: str | None = None,
    prediction_id: str | None = None,
    database_url: str | None = None,
) -> str:
    values = _soft_quote_values(quote, event_id, prediction_id)
    database_url = database_url or os.getenv("DATABASE_URL")
    placeholders = ", ".join(["%s"] * len(values))
    if database_url and database_url.startswith(("postgres://", "postgresql://")):
        import psycopg

        with psycopg.connect(database_url) as connection:
            with connection.cursor() as cursor:
                cursor.execute(SOFT_QUOTE_SCHEMA.replace(
                    "soft_quote_observations", "lol_kills.soft_quote_observations"
                ))
                cursor.execute(
                    f"INSERT INTO lol_kills.soft_quote_observations VALUES ({placeholders}) "
                    "ON CONFLICT (quote_id) DO NOTHING",
                    values,
                )
        return str(values[0])
    local_path = Path(".local") / "predictions.sqlite"
    local_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(local_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute(SOFT_QUOTE_SCHEMA)
        connection.execute(
            "INSERT OR IGNORE INTO soft_quote_observations VALUES ("
            + ", ".join(["?"] * len(values))
            + ")",
            values,
        )
    return str(values[0])


def save_pinnacle_forecast(
    quote_id: str,
    forecast: dict[str, Any],
    database_url: str | None = None,
) -> str:
    created_at = datetime.now(timezone.utc).isoformat()
    forecast_id = hashlib.sha256(
        f"{quote_id}|{forecast['model_id']}|{created_at}".encode("utf-8")
    ).hexdigest()
    values = (
        forecast_id,
        quote_id,
        created_at,
        forecast["model_id"],
        forecast["model_status"],
        forecast["forecast_target"],
        forecast.get("predicted_last_mu"),
        forecast.get("predicted_last_mu_low"),
        forecast.get("predicted_last_mu_high"),
        forecast.get("probability_over"),
        forecast.get("probability_under"),
        forecast.get("conservative_ev_over"),
        forecast.get("conservative_ev_under"),
        forecast.get("recommended_side"),
        forecast["action"],
        float(forecast.get("stake", 0.0)),
        json.dumps(forecast, ensure_ascii=False, sort_keys=True),
    )
    database_url = database_url or os.getenv("DATABASE_URL")
    if database_url and database_url.startswith(("postgres://", "postgresql://")):
        import psycopg

        with psycopg.connect(database_url) as connection:
            with connection.cursor() as cursor:
                cursor.execute(PINNACLE_FORECAST_SCHEMA.replace(
                    "pinnacle_forecasts", "lol_kills.pinnacle_forecasts"
                ).replace(
                    "soft_quote_observations", "lol_kills.soft_quote_observations"
                ))
                cursor.execute(
                    "INSERT INTO lol_kills.pinnacle_forecasts VALUES ("
                    + ", ".join(["%s"] * len(values))
                    + ")",
                    values,
                )
        return forecast_id
    local_path = Path(".local") / "predictions.sqlite"
    local_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(local_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute(SOFT_QUOTE_SCHEMA)
        connection.execute(PINNACLE_FORECAST_SCHEMA)
        connection.execute(
            "INSERT INTO pinnacle_forecasts VALUES ("
            + ", ".join(["?"] * len(values))
            + ")",
            values,
        )
    return forecast_id


def save_quote_outcome(
    quote_id: str,
    outcome: dict[str, Any],
    database_url: str | None = None,
) -> str:
    status = str(outcome.get("execution_status") or "pending")
    allowed = {"pending", "not_attempted", "accepted", "rejected", "win", "loss", "void"}
    if status not in allowed:
        raise ValueError("Status de execução inválido.")
    accepted_odds = outcome.get("accepted_odds")
    accepted_stake = outcome.get("accepted_stake")
    executed_side = outcome.get("executed_side")
    if status in {"accepted", "win", "loss"} and (
        accepted_odds is None
        or float(accepted_odds) <= 1
        or accepted_stake is None
        or float(accepted_stake) <= 0
        or executed_side not in {"over", "under"}
    ):
        raise ValueError("Execução aceita exige lado, odd e stake aceitas.")
    values = (
        quote_id,
        datetime.now(timezone.utc).isoformat(),
        status,
        executed_side,
        outcome.get("requested_odds"),
        outcome.get("requested_stake"),
        accepted_odds,
        accepted_stake,
        outcome.get("settled_at"),
        outcome.get("profit"),
        outcome.get("final_pinnacle_time"),
        outcome.get("final_pinnacle_line"),
        outcome.get("final_pinnacle_odds_over"),
        outcome.get("final_pinnacle_odds_under"),
        outcome.get("clv"),
        outcome.get("notes"),
        json.dumps(outcome, ensure_ascii=False, sort_keys=True),
    )
    database_url = database_url or os.getenv("DATABASE_URL")
    columns = (
        "quote_id, updated_at, execution_status, executed_side, requested_odds, requested_stake, "
        "accepted_odds, accepted_stake, settled_at, profit, final_pinnacle_time, "
        "final_pinnacle_line, final_pinnacle_odds_over, final_pinnacle_odds_under, "
        "clv, notes, payload_json"
    )
    if database_url and database_url.startswith(("postgres://", "postgresql://")):
        import psycopg

        with psycopg.connect(database_url) as connection:
            with connection.cursor() as cursor:
                cursor.execute(QUOTE_OUTCOME_SCHEMA.replace(
                    "quote_outcomes", "lol_kills.quote_outcomes"
                ).replace(
                    "soft_quote_observations", "lol_kills.soft_quote_observations"
                ))
                cursor.execute(
                    f"INSERT INTO lol_kills.quote_outcomes ({columns}) VALUES ("
                    + ", ".join(["%s"] * len(values))
                    + ") ON CONFLICT (quote_id) DO UPDATE SET "
                    "updated_at = EXCLUDED.updated_at, execution_status = EXCLUDED.execution_status, "
                    "executed_side = EXCLUDED.executed_side, "
                    "requested_odds = EXCLUDED.requested_odds, requested_stake = EXCLUDED.requested_stake, "
                    "accepted_odds = EXCLUDED.accepted_odds, accepted_stake = EXCLUDED.accepted_stake, "
                    "settled_at = EXCLUDED.settled_at, profit = EXCLUDED.profit, "
                    "final_pinnacle_time = EXCLUDED.final_pinnacle_time, "
                    "final_pinnacle_line = EXCLUDED.final_pinnacle_line, "
                    "final_pinnacle_odds_over = EXCLUDED.final_pinnacle_odds_over, "
                    "final_pinnacle_odds_under = EXCLUDED.final_pinnacle_odds_under, "
                    "clv = EXCLUDED.clv, notes = EXCLUDED.notes, payload_json = EXCLUDED.payload_json",
                    values,
                )
        return quote_id
    local_path = Path(".local") / "predictions.sqlite"
    local_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(local_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute(SOFT_QUOTE_SCHEMA)
        connection.execute(QUOTE_OUTCOME_SCHEMA)
        connection.execute(
            f"INSERT INTO quote_outcomes ({columns}) VALUES ("
            + ", ".join(["?"] * len(values))
            + ") ON CONFLICT(quote_id) DO UPDATE SET "
            "updated_at=excluded.updated_at, execution_status=excluded.execution_status, "
            "executed_side=excluded.executed_side, "
            "requested_odds=excluded.requested_odds, requested_stake=excluded.requested_stake, "
            "accepted_odds=excluded.accepted_odds, accepted_stake=excluded.accepted_stake, "
            "settled_at=excluded.settled_at, profit=excluded.profit, "
            "final_pinnacle_time=excluded.final_pinnacle_time, "
            "final_pinnacle_line=excluded.final_pinnacle_line, "
            "final_pinnacle_odds_over=excluded.final_pinnacle_odds_over, "
            "final_pinnacle_odds_under=excluded.final_pinnacle_odds_under, "
            "clv=excluded.clv, notes=excluded.notes, payload_json=excluded.payload_json",
            values,
        )
    return quote_id


def load_soft_quote_observations(
    database_url: str | None = None,
) -> pd.DataFrame:
    database_url = database_url or os.getenv("DATABASE_URL")
    query = """
        SELECT quote.*, outcome.execution_status, outcome.executed_side, outcome.accepted_odds,
               outcome.accepted_stake, outcome.profit, outcome.clv,
               outcome.settled_at
        FROM {quote_table} quote
        LEFT JOIN {outcome_table} outcome ON outcome.quote_id = quote.quote_id
        ORDER BY quote.observed_at DESC
    """
    if database_url and database_url.startswith(("postgres://", "postgresql://")):
        import psycopg

        with psycopg.connect(database_url) as connection:
            return pd.read_sql_query(
                query.format(
                    quote_table="lol_kills.soft_quote_observations",
                    outcome_table="lol_kills.quote_outcomes",
                ),
                connection,
            )
    local_path = Path(".local") / "predictions.sqlite"
    if not local_path.exists():
        return pd.DataFrame()
    with sqlite3.connect(local_path) as connection:
        connection.execute(SOFT_QUOTE_SCHEMA)
        connection.execute(QUOTE_OUTCOME_SCHEMA)
        return pd.read_sql_query(
            query.format(
                quote_table="soft_quote_observations",
                outcome_table="quote_outcomes",
            ),
            connection,
        )
