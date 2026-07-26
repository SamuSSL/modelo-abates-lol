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
