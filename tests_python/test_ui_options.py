from app.ui_options import team_label, team_options


def make_bundle():
    return {
        "sample_limits": {
            "team_effective_games": 2,
        },
        "teams": [
            {
                "key": "id:a",
                "team_name": "Alpha",
                "latest_team_name": "Alpha",
                "league_canonical": "LCK",
                "effective_team_games": 0.5,
                "last_game_datetime": "2025-12-20 12:00:00 UTC",
            },
            {
                "key": "id:b",
                "team_name": "Beta",
                "latest_team_name": "Beta",
                "league_canonical": "LCK",
                "effective_team_games": 5,
                "last_game_datetime": "2026-02-01 12:00:00 UTC",
            },
            {
                "key": "id:c",
                "team_name": "Gamma",
                "latest_team_name": "Gamma",
                "league_canonical": "LCK",
                "effective_team_games": 0.5,
                "last_game_datetime": "2026-03-01 12:00:00 UTC",
            },
            {
                "key": "id:b",
                "team_name": "Beta Legacy",
                "latest_team_name": "Beta",
                "league_canonical": "LCK",
                "effective_team_games": 5,
                "last_game_datetime": "2026-02-01 12:00:00 UTC",
            },
        ],
    }


def test_only_current_season_teams_are_visible():
    bundle = make_bundle()
    rows = team_options(bundle, "LCK")
    assert {row["team_name"] for row in rows} == {"Beta", "Gamma"}
    assert rows[0]["team_name"] == "Beta"
    assert "pouca amostra" in team_label(rows[1], 2)
