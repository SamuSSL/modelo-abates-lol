from __future__ import annotations

from typing import Any


def team_options(
    bundle: dict[str, Any],
    league: str,
    active_season: int = 2026,
) -> list[dict[str, Any]]:
    limit = float(bundle["sample_limits"]["team_effective_games"])
    rows = [
        row
        for row in bundle["teams"]
        if row.get("league_canonical") == league
        and str(row.get("last_game_datetime", "")).startswith(
            f"{active_season}-"
        )
        and row.get("team_name") == row.get(
            "latest_team_name",
            row.get("team_name"),
        )
    ]
    return sorted(
        rows,
        key=lambda row: (
            float(row["effective_team_games"]) < limit,
            str(row["team_name"]).casefold(),
            str(row["key"]),
        ),
    )


def team_label(row: dict[str, Any], limit: float) -> str:
    suffix = (
        ""
        if float(row["effective_team_games"]) >= limit
        else " — pouca amostra"
    )
    return f"{row['team_name']}{suffix}"


def player_options(
    bundle: dict[str, Any],
    position: str,
    team_name: str,
) -> tuple[list[dict[str, Any]], bool]:
    position_rows = [
        row
        for row in bundle["players"]
        if row["position"] == position
    ]
    team_rows = [
        row for row in position_rows if row.get("team_name") == team_name
    ]
    using_global_fallback = len(team_rows) == 0
    rows = team_rows if team_rows else position_rows
    limit = float(bundle["sample_limits"]["player_effective_games"])
    return (
        sorted(
            rows,
            key=lambda row: (
                float(row["effective_player_games"]) < limit,
                str(row["player_name"]).casefold(),
                str(row["key"]),
            ),
        ),
        using_global_fallback,
    )


def player_label(
    row: dict[str, Any],
    limit: float,
    show_team: bool = False,
) -> str:
    parts = [str(row["player_name"])]
    if show_team and row.get("team_name"):
        parts.append(str(row["team_name"]))
    if float(row["effective_player_games"]) < limit:
        parts.append("pouca amostra")
    return " — ".join(parts)
