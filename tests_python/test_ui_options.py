from app.ui_options import (
    player_label,
    player_options,
    team_label,
    team_options,
)


def make_bundle():
    return {
        "sample_limits": {
            "team_effective_games": 2,
            "player_effective_games": 2,
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
        "players": [
            {
                "key": "id:p1|top",
                "player_name": "One",
                "position": "top",
                "team_name": "Alpha",
                "effective_player_games": 0.5,
            },
            {
                "key": "id:p2|top",
                "player_name": "Two",
                "position": "top",
                "team_name": "Beta",
                "effective_player_games": 5,
            },
        ],
    }


def test_only_current_season_teams_are_visible():
    bundle = make_bundle()
    rows = team_options(bundle, "LCK")
    assert {row["team_name"] for row in rows} == {"Beta", "Gamma"}
    assert rows[0]["team_name"] == "Beta"
    assert "pouca amostra" in team_label(rows[1], 2)


def test_team_roster_is_preferred_without_hiding_low_sample_players():
    bundle = make_bundle()
    rows, fallback = player_options(bundle, "top", "Alpha")
    assert not fallback
    assert [row["player_name"] for row in rows] == ["One"]
    assert "pouca amostra" in player_label(rows[0], 2)


def test_missing_roster_uses_explicit_global_fallback():
    bundle = make_bundle()
    rows, fallback = player_options(bundle, "top", "Unknown")
    assert fallback
    assert len(rows) == 2
    assert "Beta" in player_label(rows[0], 2, show_team=True)
