from app.dota_team_identity import (
    build_operational_team_catalog,
    classify_roster_transition,
    resolve_team_identity,
)


def test_same_display_name_is_one_operational_team_with_historical_candidates() -> None:
    catalog = {
        "team_history": [
            {
                "team_id": "old",
                "team_name": "Hokori",
                "last_seen": "2026-04-13T00:00:00Z",
                "map_count": 20,
            },
            {
                "team_id": "new",
                "team_name": "Hokori",
                "last_seen": "2026-06-17T00:00:00Z",
                "map_count": 8,
            },
        ]
    }

    rows = build_operational_team_catalog(catalog, {})

    assert len(rows) == 1
    assert rows[0]["canonical_team_name"] == "Hokori"
    assert {
        row["opendota_team_id"] for row in rows[0]["historical_identities"]
    } == {"old", "new"}


def test_resolver_never_uses_identity_after_cutoff() -> None:
    candidates = [
        {"opendota_team_id": "old", "last_seen": "2026-04-13T00:00:00Z"},
        {"opendota_team_id": "future", "last_seen": "2026-08-01T00:00:00Z"},
    ]

    result = resolve_team_identity(candidates, "2026-06-01T00:00:00Z")

    assert result["opendota_team_id"] == "old"


def test_four_changed_players_create_new_roster_version() -> None:
    result = classify_roster_transition([1, 2, 3, 4, 5], [1, 6, 7, 8, 9])

    assert result["overlap_count"] == 1
    assert result["roster_status"] == "new_roster_version"


def test_latest_stale_identity_is_available_for_manual_comparison() -> None:
    result = resolve_team_identity(
        [{
            "opendota_team_id": "old",
            "last_seen": "2026-04-13T00:00:00Z",
            "roster_status": "current_membership_incomplete",
        }],
        "2026-09-18T00:00:00Z",
    )

    assert result["identity_status"] == "stale"
    assert result["opendota_team_id"] == "old"
    assert result["manual_comparison_blocked"] is False


def test_approved_event_identity_wins_when_available_before_cutoff() -> None:
    candidates = [
        {"opendota_team_id": "old", "last_seen": "2026-06-01T00:00:00Z"},
        {"opendota_team_id": "event", "last_seen": "2026-05-20T00:00:00Z"},
    ]

    result = resolve_team_identity(
        candidates,
        "2026-06-15T00:00:00Z",
        approved_event_team_id="event",
    )

    assert result["opendota_team_id"] == "event"
    assert result["resolution_method"] == "approved_event_identity"


def test_missing_roster_is_explicitly_unknown() -> None:
    result = classify_roster_transition([], ["1", "2", "3", "4", "5"])

    assert result["roster_status"] == "unknown"
    assert result["overlap_count"] is None


def test_roster_evidence_after_cutoff_is_not_used() -> None:
    result = resolve_team_identity(
        [
            {
                "opendota_team_id": "team",
                "last_seen": "2026-06-01T00:00:00Z",
                "roster_status": "current_membership_observed",
                "roster_evidence_retrieved_at": "2026-09-18T00:00:00Z",
            }
        ],
        "2026-06-15T00:00:00Z",
    )

    assert result["roster_available_before_cutoff"] is False
    assert result["roster_status"] == "unknown"
    assert result["manual_comparison_blocked"] is False
