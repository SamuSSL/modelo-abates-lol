import copy
import json
import math
from pathlib import Path

import pytest

from app.lolkills_inference import predict
from app.predraft_contract import (
    evaluate_operational_gate,
    evaluate_roster_gate,
    legacy_request_from_predraft,
    normalize_predraft_request,
    roster_signature,
)
from app.shadow_models import (
    build_operational_prediction,
    build_shadow_predictions,
    evaluate_model_agreement,
)


def make_request(bundle):
    teams = [
        row
        for row in bundle["teams"]
        if row["league_canonical"] == "LCK"
        and float(row["effective_team_games"])
        >= float(bundle["sample_limits"]["team_effective_games"])
    ][:2]
    starters_a = [
        {"player_id": f"a-{index}", "player_name": f"A {index}"}
        for index in range(5)
    ]
    starters_b = [
        {"player_id": f"b-{index}", "player_name": f"B {index}"}
        for index in range(5)
    ]
    return {
        "league": "LCK",
        "planned_at": "2026-08-08T12:00:00+00:00",
        "quoted_at": "2026-08-08T11:25:00+00:00",
        "map_number": 1,
        "team_a": {
            "team_id": teams[0].get("team_id"),
            "team_name": teams[0]["team_name"],
            "starters": starters_a,
        },
        "team_b": {
            "team_id": teams[1].get("team_id"),
            "team_name": teams[1]["team_name"],
            "starters": starters_b,
        },
        "moneyline_team_a_odds": 1.75,
        "moneyline_team_b_odds": 2.10,
        "soft_line": 27.5,
        "soft_odds_over": 2.02,
        "soft_odds_under": 1.88,
        "pinnacle_total_line": 28.5,
        "pinnacle_total_odds_over": 1.93,
        "pinnacle_total_odds_under": 1.97,
    }


@pytest.fixture
def bundle():
    return json.loads(
        Path("app_data/model_bundle.json").read_text(encoding="utf-8")
    )


def test_predraft_contract_requires_both_soft_odds(bundle):
    request = make_request(bundle)
    request["soft_odds_under"] = None
    with pytest.raises(ValueError):
        normalize_predraft_request(request)


def test_predraft_contract_accepts_manual_soft_observation(bundle):
    request = make_request(bundle)
    request.update(
        {
            "bookmaker": "Soft Test",
            "quote_stage": "first_seen",
            "observed_at": "2026-08-08T11:25:00+00:00",
        }
    )
    normalized = normalize_predraft_request(request)
    assert normalized["bookmaker"] == "Soft Test"
    assert normalized["quote_stage"] == "first_seen"


def test_predraft_contract_rejects_invalid_quote_stage(bundle):
    request = make_request(bundle)
    request["bookmaker"] = "Soft Test"
    request["quote_stage"] = "opening"
    with pytest.raises(ValueError, match="quote_stage"):
        normalize_predraft_request(request)


def test_optional_team_totals_require_complete_triplet(bundle):
    request = make_request(bundle)
    request["team_a_total_line"] = 15.5
    with pytest.raises(ValueError):
        normalize_predraft_request(request)


def test_operational_gate_blocks_quotes_outside_t45_t30(bundle):
    request = make_request(bundle)
    request["quoted_at"] = "2026-08-08T11:00:00+00:00"
    gate = evaluate_operational_gate(request, bundle["metadata"])
    assert gate["blocked"] is True
    assert any("T-45/T-30" in reason for reason in gate["reasons"])


def test_operational_gate_accepts_postdraft_live_open(bundle):
    request = make_request(bundle)
    request["quoted_at"] = "2026-08-08T12:02:00+00:00"
    request["analysis_timing"] = "postdraft_live_open"
    gate = evaluate_operational_gate(request, bundle["metadata"])
    assert gate["prediction_anchor"] == "postdraft_live_open"
    assert gate["snapshot_window_minutes"] is None
    assert not any("T-45/T-30" in reason for reason in gate["reasons"])


def test_operational_gate_blocks_stale_weekly_bundle(bundle):
    request = make_request(bundle)
    request["planned_at"] = "2026-08-09T12:00:00+00:00"
    request["quoted_at"] = "2026-08-09T11:25:00+00:00"
    gate = evaluate_operational_gate(request, bundle["metadata"])
    assert gate["blocked"] is True
    assert any("Bundle semanal vencido" in reason for reason in gate["reasons"])


def test_legacy_mapping_swaps_teams_and_moneyline(bundle):
    request = make_request(bundle)
    first = legacy_request_from_predraft(request)
    swapped = legacy_request_from_predraft(request, swap=True)
    assert first["blue"]["team_name"] == swapped["red"]["team_name"]
    assert first["moneyline_blue_odds"] == swapped["moneyline_red_odds"]


def test_roster_gate_preserves_name_change_with_same_players(bundle):
    request = make_request(bundle)
    signature_a = roster_signature(request["team_a"]["starters"])
    signature_b = roster_signature(request["team_b"]["starters"])
    catalog = {
        "teams": {
            request["team_a"]["team_id"]: {
                "latest_roster": [row["player_id"] for row in request["team_a"]["starters"]]
            },
            request["team_b"]["team_id"]: {
                "latest_roster": [row["player_id"] for row in request["team_b"]["starters"]]
            },
        },
        "roster_signatures": {
            signature_a: {"maps": 12},
            signature_b: {"maps": 8},
        },
    }
    request["team_a"]["team_name"] = "Nova Organizacao"
    assert evaluate_roster_gate(request, catalog)["blocked"] is False


def test_two_changes_block_until_fifth_map(bundle):
    request = make_request(bundle)
    changed = copy.deepcopy(request["team_a"]["starters"])
    changed[0]["player_id"] = "new-1"
    changed[1]["player_id"] = "new-2"
    request["team_a"]["starters"] = changed
    signature = roster_signature(changed)
    catalog = {
        "teams": {
            request["team_a"]["team_id"]: {
                "latest_roster": [f"a-{index}" for index in range(5)]
            },
            request["team_b"]["team_id"]: {
                "latest_roster": [f"b-{index}" for index in range(5)]
            },
        },
        "roster_signatures": {signature: {"maps": 4}},
    }
    assert evaluate_roster_gate(request, catalog)["blocked"] is True
    catalog["roster_signatures"][signature]["maps"] = 5
    assert evaluate_roster_gate(request, catalog)["blocked"] is False


def test_shadow_market_exact_reproduces_pinnacle_probability(bundle):
    request = make_request(bundle)
    visible = predict(legacy_request_from_predraft(request), bundle)
    rows = build_shadow_predictions(request, visible, bundle)
    exact = next(row for row in rows if row["model_id"] == "market_implied_nb_exact")
    assert exact["probability_over_pinnacle"] == pytest.approx(
        exact["diagnostics"]["pinnacle_probability_over"],
        abs=2e-8,
    )
    assert [row["minimum_ev"] for row in exact["paper_rules"]] == [
        0.0,
        0.03,
        0.05,
        0.08,
        0.10,
    ]


def test_shadow_records_complete_team_total_diagnostics(bundle):
    request = make_request(bundle)
    request.update(
        {
            "team_a_total_line": 15.5,
            "team_a_total_odds_over": 1.91,
            "team_a_total_odds_under": 1.99,
            "team_b_total_line": 12.5,
            "team_b_total_odds_over": 1.95,
            "team_b_total_odds_under": 1.95,
        }
    )
    visible = predict(legacy_request_from_predraft(request), bundle)
    rows = build_shadow_predictions(request, visible, bundle)
    exact = next(row for row in rows if row["model_id"] == "market_implied_nb_exact")
    diagnostics = exact["diagnostics"]
    assert diagnostics["team_total_sum"] == pytest.approx(
        diagnostics["team_a_implied_mean"]
        + diagnostics["team_b_implied_mean"]
    )
    assert diagnostics["team_a_implied_share"] + diagnostics[
        "team_b_implied_share"
    ] == pytest.approx(1.0)
    assert diagnostics["team_total_sum_gap"] == pytest.approx(
        diagnostics["team_total_sum"] - diagnostics["implied_mean"]
    )


def test_market_directed_blend_is_logged_as_prospective_only(bundle):
    request = make_request(bundle)
    visible = predict(legacy_request_from_predraft(request), bundle)
    rows = build_shadow_predictions(request, visible, bundle)
    exact = next(row for row in rows if row["model_id"] == "market_implied_nb_exact")
    blend = next(
        row for row in rows if row["model_id"] == "market_directed_blend_w070"
    )
    expected_mean = math.exp(
        0.7 * math.log(visible["mean"])
        + 0.3 * math.log(exact["diagnostics"]["implied_mean"])
    )
    assert blend["mean"] == pytest.approx(expected_mean, abs=1e-8)
    assert blend["mode"] == "prospective_diagnostic"
    assert (
        blend["diagnostics"]["selection_status"]
        == "prospective_only_not_promoted"
    )


def test_shadow_uses_fundamental_fallback(bundle):
    request = make_request(bundle)
    request["pinnacle_total_line"] = None
    request["pinnacle_total_odds_over"] = None
    request["pinnacle_total_odds_under"] = None
    visible = predict(legacy_request_from_predraft(request), bundle)
    rows = build_shadow_predictions(request, visible, bundle)
    fallback = next(row for row in rows if row["model_id"] == "market_implied_count")
    assert fallback["mode"] == "fundamental_fallback"


def test_operational_prediction_uses_pinnacle_when_available(bundle):
    request = make_request(bundle)
    visible = predict(legacy_request_from_predraft(request), bundle)
    rows = build_shadow_predictions(request, visible, bundle)
    operational = build_operational_prediction(request, visible, rows)
    exact = next(row for row in rows if row["model_id"] == "market_implied_nb_exact")
    assert operational["prediction_source"] == "pinnacle_postdraft"
    assert operational["fallback_used"] is False
    assert operational["probability_over"] == pytest.approx(
        exact["probability_over_soft"]
    )


def test_operational_prediction_falls_back_to_directed(bundle):
    request = make_request(bundle)
    request["pinnacle_total_line"] = None
    request["pinnacle_total_odds_over"] = None
    request["pinnacle_total_odds_under"] = None
    visible = predict(legacy_request_from_predraft(request), bundle)
    rows = build_shadow_predictions(request, visible, bundle)
    operational = build_operational_prediction(request, visible, rows)
    assert operational["prediction_source"] == "directed_moneyline_fallback"
    assert operational["fallback_used"] is True
    assert operational["pmf"] == pytest.approx(visible["pmf"])
    assert operational["model_agreement"]["status"] == "unavailable"


@pytest.mark.parametrize(
    (
        "odds",
        "structural_over",
        "pinnacle_over",
        "expected_status",
        "expected_message",
        "expected_stake",
        "expected_side",
    ),
    [
        (
            2.0,
            0.60,
            0.55,
            "bet_agreement",
            "Modelos concordam em uma aposta. Over confirmado.",
            1.0,
            "over",
        ),
        (
            1.9,
            0.60,
            0.51,
            "high_trend",
            "Confiança alta de tendência. Sinal verde para Over.",
            1.0,
            "over",
        ),
        (
            1.95,
            0.60,
            0.40,
            "opposing_positive_ev",
            "Modelos divergem. Apostar 0.5u no lado da Pinnacle: Under.",
            0.5,
            "under",
        ),
        (
            1.9,
            0.51,
            0.49,
            "no_value",
            "Nenhum valor indicado. Não apostar.",
            None,
            None,
        ),
        (
            1.9,
            0.60,
            0.49,
            "one_sided_directional_disagreement",
            "Pinnacle se opõe ao sinal estrutural. Não apostar.",
            None,
            None,
        ),
        (
            1.9,
            0.49,
            0.60,
            "pinnacle_only_value",
            "Pinnacle indica valor. Apostar 0.5u no lado da Pinnacle: Over.",
            0.5,
            "over",
        ),
    ],
)
def test_confiometer_uses_positive_ev_states(
    odds,
    structural_over,
    pinnacle_over,
    expected_status,
    expected_message,
    expected_stake,
    expected_side,
):
    request = {
        "soft_odds_over": odds,
        "soft_odds_under": odds,
    }
    structural = {
        "probability_over": structural_over,
        "probability_under": 1 - structural_over,
    }
    pinnacle = {
        "probability_over_soft": pinnacle_over,
        "probability_under_soft": 1 - pinnacle_over,
    }
    agreement = evaluate_model_agreement(request, structural, pinnacle)
    assert agreement["status"] == expected_status
    assert agreement["message"] == expected_message
    assert agreement["recommended_stake"] == expected_stake
    assert agreement["recommended_side"] == expected_side


def test_confiometer_treats_tiny_market_difference_as_neutral():
    request = {
        "soft_odds_over": 1.78,
        "soft_odds_under": 1.85,
    }
    structural = {
        "mean": 28.0,
        "probability_over": 0.40,
        "probability_under": 0.60,
    }
    pinnacle = {
        "mean": 29.5,
        "probability_over_soft": 0.51,
        "probability_under_soft": 0.49,
    }
    agreement = evaluate_model_agreement(request, structural, pinnacle)
    assert agreement["status"] == "single_model_value_other_neutral"
    assert agreement["pinnacle_signal_side"] is None
    assert agreement["structural_signal_side"] == "under"
    assert agreement["message"] == (
        "Somente o modelo estrutural indica valor; Pinnacle neutra."
    )
    assert agreement["recommended_side"] == "under"
    assert agreement["recommended_stake"] == 0.5
    assert agreement["recommended_model"] == "structural"


def test_confiometer_flags_extreme_mean_disagreement():
    request = {
        "soft_odds_over": 1.78,
        "soft_odds_under": 1.85,
    }
    structural = {
        "mean": 24.9,
        "probability_over": 0.27,
        "probability_under": 0.73,
    }
    pinnacle = {
        "mean": 30.4,
        "probability_over_soft": 0.51,
        "probability_under_soft": 0.49,
    }
    agreement = evaluate_model_agreement(request, structural, pinnacle)
    assert agreement["status"] == "extreme_mean_disagreement"
    assert agreement["extreme_mean_disagreement"] is True
    assert agreement["mean_disagreement_kills"] == pytest.approx(-5.5)
    assert agreement["message"] == (
        "Divergência extrema entre estrutural e Pinnacle. "
        "Não tratar como confiança alta."
    )
    assert agreement["recommended_side"] is None
    assert agreement["recommended_stake"] is None


def test_predraft_prediction_is_invariant_to_team_order(bundle):
    request = make_request(bundle)
    signatures = {
        roster_signature(request[label]["starters"]): {"maps": 10}
        for label in ("team_a", "team_b")
    }
    catalog = {
        "teams": {
            request[label]["team_id"]: {
                "latest_roster": [
                    row["player_id"] for row in request[label]["starters"]
                ]
            }
            for label in ("team_a", "team_b")
        },
        "roster_signatures": signatures,
    }
    inference_bundle = copy.deepcopy(bundle)
    inference_bundle["roster_catalog"] = catalog
    first = predict(request, inference_bundle)
    swapped_request = copy.deepcopy(request)
    swapped_request["team_a"], swapped_request["team_b"] = (
        swapped_request["team_b"],
        swapped_request["team_a"],
    )
    (
        swapped_request["moneyline_team_a_odds"],
        swapped_request["moneyline_team_b_odds"],
    ) = (
        swapped_request["moneyline_team_b_odds"],
        swapped_request["moneyline_team_a_odds"],
    )
    second = predict(swapped_request, inference_bundle)
    assert first["status"] == second["status"] == "ok"
    assert first["no_vig_method"] == "proportional_normalization"
    assert first["prediction_id"] == second["prediction_id"]
    assert first["pmf"] == pytest.approx(second["pmf"], abs=1e-14)
    assert first["features"]["team_a_mean"] == pytest.approx(
        second["features"]["team_b_mean"]
    )
