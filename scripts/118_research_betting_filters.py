from __future__ import annotations

import json
from pathlib import Path
import sys
from typing import Callable

import numpy as np
import pandas as pd


PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from app.lolkills_inference import negative_binomial_pmf
from app.shadow_models import evaluate_model_agreement


INPUT_PATH = (
    PROJECT_ROOT
    / "artifacts"
    / "modeling-research"
    / "pinnacle-market-anchored-model"
    / "research-dataset.csv"
)
OUTPUT_DIR = (
    PROJECT_ROOT
    / "artifacts"
    / "modeling-research"
    / "betting-filter-research"
)
SELECTION_SAMPLE = "selection_may"
CONFIRMATION_SAMPLE = "confirmation_jun_jul"
MINIMUM_SELECTION_BETS = 50
BOOTSTRAP_DRAWS = 5000
RANDOM_SEED = 20260805


def probability_over(mean: float, theta: float, line: float) -> float:
    pmf = negative_binomial_pmf(float(mean), float(theta))
    threshold = int(np.floor(float(line)))
    return 1.0 - float(sum(pmf[: threshold + 1]))


def settle(side: str, observed: float, line: float, odds: float, stake: float) -> float:
    won = observed > line if side == "over" else observed < line
    return stake * (odds - 1.0) if won else -stake


def maximum_drawdown(profits: pd.Series) -> float:
    cumulative = profits.cumsum()
    peak = cumulative.cummax().clip(lower=0.0)
    return float((peak - cumulative).max()) if len(profits) else 0.0


def build_decision_rows(data: pd.DataFrame, timing_id: str) -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    if timing_id == "pre_t15":
        line_field = "t15_line"
        odds_over_field = "t15_odds_over"
        odds_under_field = "t15_odds_under"
        market_probability_field = "t15_probability_over"
        market_mean_field = "t15_market_mean"
    elif timing_id == "live_open":
        line_field = "live_line"
        odds_over_field = "live_odds_over"
        odds_under_field = "live_odds_under"
        market_probability_field = "market_probability_over"
        market_mean_field = "market_mean"
    else:
        raise ValueError(f"Unsupported timing: {timing_id}")
    for _, row in data.iterrows():
        structural_probability_over = probability_over(
            row["structural_mean"],
            row["structural_theta"],
            row[line_field],
        )
        structural = {
            "probability_over": structural_probability_over,
            "probability_under": 1.0 - structural_probability_over,
            "mean": float(row["structural_mean"]),
        }
        pinnacle = {
            "probability_over_soft": float(row[market_probability_field]),
            "probability_under_soft": 1.0 - float(row[market_probability_field]),
            "mean": float(row[market_mean_field]),
        }
        request = {
            "soft_odds_over": float(row[odds_over_field]),
            "soft_odds_under": float(row[odds_under_field]),
        }
        decision = evaluate_model_agreement(request, structural, pinnacle)
        side = decision.get("recommended_side")
        stake = float(decision.get("recommended_stake") or 0.0)
        if side is None or stake <= 0:
            continue
        structural_probability = float(structural[f"probability_{side}"])
        market_probability = float(pinnacle[f"probability_{side}_soft"])
        offered_odds = float(
            row[odds_over_field] if side == "over" else row[odds_under_field]
        )
        observed_side = float(
            row["observed_total"] > row[line_field]
            if side == "over"
            else row["observed_total"] < row[line_field]
        )
        fictional_odds = 1.03 / market_probability
        rows.append(
            {
                **row.to_dict(),
                "timing_id": timing_id,
                "decision_line": float(row[line_field]),
                "decision_market_mean": float(row[market_mean_field]),
                "absolute_decision_disagreement": abs(
                    float(row["structural_mean"]) - float(row[market_mean_field])
                ),
                "status": decision["status"],
                "recommended_side": side,
                "base_stake": stake,
                "structural_probability_side": structural_probability,
                "market_probability_side": market_probability,
                "probability_edge_side": structural_probability - market_probability,
                "structural_ev_at_pinnacle": structural_probability * offered_odds - 1.0,
                "observed_side": observed_side,
                "structural_brier": (structural_probability - observed_side) ** 2,
                "market_brier": (market_probability - observed_side) ** 2,
                "structural_log_loss": -np.log(
                    np.clip(
                        structural_probability if observed_side else 1.0 - structural_probability,
                        1e-12,
                        1.0,
                    )
                ),
                "market_log_loss": -np.log(
                    np.clip(
                        market_probability if observed_side else 1.0 - market_probability,
                        1e-12,
                        1.0,
                    )
                ),
                "excess_hit_vs_market": observed_side - market_probability,
                "pinnacle_execution_odds": offered_odds,
                "pinnacle_profit": settle(
                    side,
                    float(row["observed_total"]),
                    float(row[line_field]),
                    offered_odds,
                    stake,
                ),
                "fictional_odds_3pct": fictional_odds,
                "fictional_stake": 1.0,
                "fictional_profit": settle(
                    side,
                    float(row["observed_total"]),
                    float(row[line_field]),
                    fictional_odds,
                    1.0,
                ),
            }
        )
    result = pd.DataFrame(rows)
    return result.sort_values(["game_datetime", "gameid"]).reset_index(drop=True)


FILTERS: dict[str, Callable[[pd.DataFrame], pd.Series]] = {
    "no_additional_filter": lambda x: pd.Series(True, index=x.index),
    "structural_ev_ge_2pct": lambda x: x["structural_ev_at_pinnacle"] >= 0.02,
    "structural_ev_ge_4pct": lambda x: x["structural_ev_at_pinnacle"] >= 0.04,
    "structural_ev_ge_6pct": lambda x: x["structural_ev_at_pinnacle"] >= 0.06,
    "probability_edge_ge_5pp": lambda x: x["probability_edge_side"] >= 0.05,
    "market_moved_toward_structural": lambda x: x["movement_toward_structural"]
    == "toward_structural",
    "market_not_away_from_structural": lambda x: x["movement_toward_structural"]
    != "away_from_structural",
    "mean_disagreement_le_2_5": lambda x: x["absolute_decision_disagreement"] <= 2.5,
    "odds_only_line_unchanged": lambda x: x["line_delta"] == 0,
    "ev4_and_market_not_away": lambda x: (
        (x["structural_ev_at_pinnacle"] >= 0.04)
        & (x["movement_toward_structural"] != "away_from_structural")
    ),
    "ev4_and_disagreement_le_3": lambda x: (
        (x["structural_ev_at_pinnacle"] >= 0.04)
        & (x["absolute_decision_disagreement"] <= 3.0)
    ),
    "ev4_not_away_disagreement_le_3": lambda x: (
        (x["structural_ev_at_pinnacle"] >= 0.04)
        & (x["movement_toward_structural"] != "away_from_structural")
        & (x["absolute_decision_disagreement"] <= 3.0)
    ),
}

PRE_FILTER_IDS = (
    "no_additional_filter",
    "structural_ev_ge_2pct",
    "structural_ev_ge_4pct",
    "structural_ev_ge_6pct",
    "probability_edge_ge_5pp",
    "mean_disagreement_le_2_5",
    "ev4_and_disagreement_le_3",
)


def summarize(
    frame: pd.DataFrame,
    filter_id: str,
    sample: str,
    timing_id: str,
) -> dict[str, object]:
    pinnacle_stake = float(frame["base_stake"].sum())
    fictional_stake = float(frame["fictional_stake"].sum())
    pinnacle_profit = float(frame["pinnacle_profit"].sum())
    fictional_profit = float(frame["fictional_profit"].sum())
    return {
        "sample": sample,
        "timing_id": timing_id,
        "filter_id": filter_id,
        "bets": int(len(frame)),
        "series": int(frame["series_id"].nunique()),
        "over_bets": int((frame["recommended_side"] == "over").sum()),
        "under_bets": int((frame["recommended_side"] == "under").sum()),
        "hit_rate": float(frame["observed_side"].mean()) if len(frame) else np.nan,
        "market_expected_hit_rate": float(frame["market_probability_side"].mean())
        if len(frame)
        else np.nan,
        "excess_hit_vs_market": float(frame["excess_hit_vs_market"].mean())
        if len(frame)
        else np.nan,
        "structural_brier": float(frame["structural_brier"].mean())
        if len(frame)
        else np.nan,
        "market_brier": float(frame["market_brier"].mean()) if len(frame) else np.nan,
        "brier_delta": float((frame["structural_brier"] - frame["market_brier"]).mean())
        if len(frame)
        else np.nan,
        "structural_log_loss": float(frame["structural_log_loss"].mean())
        if len(frame)
        else np.nan,
        "market_log_loss": float(frame["market_log_loss"].mean())
        if len(frame)
        else np.nan,
        "log_loss_delta": float(
            (frame["structural_log_loss"] - frame["market_log_loss"]).mean()
        )
        if len(frame)
        else np.nan,
        "pinnacle_stake": pinnacle_stake,
        "pinnacle_profit": pinnacle_profit,
        "pinnacle_yield": pinnacle_profit / pinnacle_stake if pinnacle_stake else np.nan,
        "pinnacle_max_drawdown": maximum_drawdown(frame["pinnacle_profit"]),
        "fictional_stake": fictional_stake,
        "fictional_profit": fictional_profit,
        "fictional_yield": fictional_profit / fictional_stake if fictional_stake else np.nan,
        "fictional_max_drawdown": maximum_drawdown(frame["fictional_profit"]),
    }


def bootstrap_confirmation(
    frame: pd.DataFrame,
    filter_id: str,
    timing_id: str,
) -> pd.DataFrame:
    grouped = frame.groupby("series_id", sort=False).agg(
        brier_delta=("structural_brier", "sum"),
        market_brier_sum=("market_brier", "sum"),
        structural_brier_sum=("structural_brier", "sum"),
        market_log_sum=("market_log_loss", "sum"),
        structural_log_sum=("structural_log_loss", "sum"),
        excess_hit_sum=("excess_hit_vs_market", "sum"),
        bets=("gameid", "size"),
        pinnacle_profit=("pinnacle_profit", "sum"),
        pinnacle_stake=("base_stake", "sum"),
        fictional_profit=("fictional_profit", "sum"),
        fictional_stake=("fictional_stake", "sum"),
    )
    if grouped.empty:
        return pd.DataFrame()
    grouped["brier_delta"] = (
        grouped["structural_brier_sum"] - grouped["market_brier_sum"]
    )
    grouped["log_loss_delta"] = grouped["structural_log_sum"] - grouped["market_log_sum"]
    values = grouped.to_numpy(dtype=float)
    columns = {name: index for index, name in enumerate(grouped.columns)}
    rng = np.random.default_rng(RANDOM_SEED + len(filter_id) + len(timing_id))
    draws: dict[str, np.ndarray] = {
        "brier_delta": np.empty(BOOTSTRAP_DRAWS),
        "log_loss_delta": np.empty(BOOTSTRAP_DRAWS),
        "excess_hit_vs_market": np.empty(BOOTSTRAP_DRAWS),
        "pinnacle_yield": np.empty(BOOTSTRAP_DRAWS),
        "fictional_yield": np.empty(BOOTSTRAP_DRAWS),
    }
    for draw in range(BOOTSTRAP_DRAWS):
        sample = values[rng.integers(0, len(values), size=len(values))]
        bets = sample[:, columns["bets"]].sum()
        draws["brier_delta"][draw] = sample[:, columns["brier_delta"]].sum() / bets
        draws["log_loss_delta"][draw] = sample[:, columns["log_loss_delta"]].sum() / bets
        draws["excess_hit_vs_market"][draw] = (
            sample[:, columns["excess_hit_sum"]].sum() / bets
        )
        draws["pinnacle_yield"][draw] = (
            sample[:, columns["pinnacle_profit"]].sum()
            / sample[:, columns["pinnacle_stake"]].sum()
        )
        draws["fictional_yield"][draw] = (
            sample[:, columns["fictional_profit"]].sum()
            / sample[:, columns["fictional_stake"]].sum()
        )
    rows = []
    lower_is_better = {"brier_delta", "log_loss_delta"}
    for metric, values_drawn in draws.items():
        estimate = {
            "brier_delta": float(
                (frame["structural_brier"] - frame["market_brier"]).mean()
            ),
            "log_loss_delta": float(
                (frame["structural_log_loss"] - frame["market_log_loss"]).mean()
            ),
            "excess_hit_vs_market": float(frame["excess_hit_vs_market"].mean()),
            "pinnacle_yield": float(frame["pinnacle_profit"].sum() / frame["base_stake"].sum()),
            "fictional_yield": float(
                frame["fictional_profit"].sum() / frame["fictional_stake"].sum()
            ),
        }[metric]
        favorable = values_drawn < 0 if metric in lower_is_better else values_drawn > 0
        rows.append(
            {
                "filter_id": filter_id,
                "timing_id": timing_id,
                "metric": metric,
                "bets": len(frame),
                "series": len(grouped),
                "estimate": estimate,
                "lower_95": float(np.quantile(values_drawn, 0.025)),
                "upper_95": float(np.quantile(values_drawn, 0.975)),
                "probability_favorable": float(favorable.mean()),
            }
        )
    return pd.DataFrame(rows)


def main() -> None:
    data = pd.read_csv(INPUT_PATH)
    data["game_datetime"] = pd.to_datetime(data["game_datetime"], utc=True)
    decisions = pd.concat(
        [
            build_decision_rows(data, "pre_t15"),
            build_decision_rows(data, "live_open"),
        ],
        ignore_index=True,
    )

    selection_rows = []
    selected_filters: dict[str, str] = {}
    selection_reasons: dict[str, str] = {}
    for timing_id in ("pre_t15", "live_open"):
        selection = decisions.loc[
            (decisions["sample"] == SELECTION_SAMPLE)
            & (decisions["timing_id"] == timing_id)
        ].copy()
        filter_ids = PRE_FILTER_IDS if timing_id == "pre_t15" else tuple(FILTERS)
        for filter_id in filter_ids:
            selected = selection.loc[FILTERS[filter_id](selection)].copy()
            selection_rows.append(
                summarize(selected, filter_id, SELECTION_SAMPLE, timing_id)
            )
    selection_summary = pd.DataFrame(selection_rows)
    for timing_id in ("pre_t15", "live_open"):
        timing_selection = selection_summary.loc[
            selection_summary["timing_id"] == timing_id
        ]
        eligible = timing_selection.loc[
            (timing_selection["filter_id"] != "no_additional_filter")
            & (timing_selection["bets"] >= MINIMUM_SELECTION_BETS)
            & (timing_selection["brier_delta"] < 0)
            & (timing_selection["log_loss_delta"] < 0)
        ].copy()
        if eligible.empty:
            selected_filters[timing_id] = "no_additional_filter"
            selection_reasons[timing_id] = (
                "No additional filter passed both proper-score gates."
            )
        else:
            eligible = eligible.sort_values(
                ["log_loss_delta", "brier_delta", "bets"],
                ascending=[True, True, False],
            )
            selected_filters[timing_id] = str(eligible.iloc[0]["filter_id"])
            selection_reasons[timing_id] = (
                "Best selection log-loss delta among filters with at least "
                f"{MINIMUM_SELECTION_BETS} bets and improvement in both proper scores."
            )

    confirmation_rows = []
    all_confirmation_rows = []
    confirmation_map_rows = []
    for timing_id in ("pre_t15", "live_open"):
        confirmation = decisions.loc[
            (decisions["sample"] == CONFIRMATION_SAMPLE)
            & (decisions["timing_id"] == timing_id)
        ].copy()
        filter_ids = PRE_FILTER_IDS if timing_id == "pre_t15" else tuple(FILTERS)
        for filter_id in filter_ids:
            selected = confirmation.loc[FILTERS[filter_id](confirmation)].copy()
            all_confirmation_rows.append(
                summarize(selected, filter_id, CONFIRMATION_SAMPLE, timing_id)
            )
        for filter_id in {
            "no_additional_filter",
            selected_filters[timing_id],
        }:
            selected = confirmation.loc[FILTERS[filter_id](confirmation)].copy()
            selected["filter_id"] = filter_id
            confirmation_map_rows.append(selected)
            confirmation_rows.append(
                summarize(selected, filter_id, CONFIRMATION_SAMPLE, timing_id)
            )
    confirmation_summary = pd.DataFrame(confirmation_rows).drop_duplicates(
        ["timing_id", "filter_id"]
    )
    all_confirmation_summary = pd.DataFrame(all_confirmation_rows)
    confirmation_maps = pd.concat(confirmation_map_rows, ignore_index=True).drop_duplicates(
        ["gameid", "timing_id", "filter_id"]
    )
    bootstrap = pd.concat(
        [
            bootstrap_confirmation(
                confirmation_maps.loc[
                    (confirmation_maps["filter_id"] == row.filter_id)
                    & (confirmation_maps["timing_id"] == row.timing_id)
                ],
                row.filter_id,
                row.timing_id,
            )
            for row in confirmation_summary.itertuples()
        ],
        ignore_index=True,
    )

    league_rows = []
    for row in confirmation_summary.itertuples():
        filtered = confirmation_maps.loc[
            (confirmation_maps["filter_id"] == row.filter_id)
            & (confirmation_maps["timing_id"] == row.timing_id)
        ]
        for league, league_frame in filtered.groupby("league_canonical"):
            league_row = summarize(
                league_frame,
                row.filter_id,
                CONFIRMATION_SAMPLE,
                row.timing_id,
            )
            league_row["league_canonical"] = league
            league_rows.append(league_row)
    by_league = pd.DataFrame(league_rows)

    baseline_confirmation = decisions.loc[
        decisions["sample"] == CONFIRMATION_SAMPLE
    ].copy()
    baseline_confirmation["calendar_month"] = pd.to_datetime(
        baseline_confirmation["game_datetime"], utc=True
    ).dt.strftime("%Y-%m")
    side_rows = []
    month_rows = []
    for (timing_id, side), frame in baseline_confirmation.groupby(
        ["timing_id", "recommended_side"]
    ):
        row = summarize(
            frame,
            "no_additional_filter",
            CONFIRMATION_SAMPLE,
            timing_id,
        )
        row["recommended_side"] = side
        side_rows.append(row)
    for (timing_id, month), frame in baseline_confirmation.groupby(
        ["timing_id", "calendar_month"]
    ):
        row = summarize(
            frame,
            "no_additional_filter",
            CONFIRMATION_SAMPLE,
            timing_id,
        )
        row["calendar_month"] = month
        month_rows.append(row)
    by_side = pd.DataFrame(side_rows)
    by_month = pd.DataFrame(month_rows)

    decisions_by_timing = {}
    for timing_id, selected_filter in selected_filters.items():
        selected_confirmation = confirmation_summary.loc[
            (confirmation_summary["timing_id"] == timing_id)
            & (confirmation_summary["filter_id"] == selected_filter)
        ].iloc[0]
        decisions_by_timing[timing_id] = {
            "selected_filter": selected_filter,
            "selection_reason": selection_reasons[timing_id],
            "confirmation_bets": int(selected_confirmation["bets"]),
            "statistical_success": bool(
                selected_confirmation["brier_delta"] < 0
                and selected_confirmation["log_loss_delta"] < 0
            ),
            "pinnacle_economic_success": bool(
                selected_confirmation["pinnacle_yield"] > 0
            ),
            "fictional_economic_success": bool(
                selected_confirmation["fictional_yield"] > 0
            ),
        }
    decision = {
        "experiment_id": "FILTER-01",
        "timings": decisions_by_timing,
        "selection_maps": int((data["sample"] == SELECTION_SAMPLE).sum()),
        "confirmation_maps": int((data["sample"] == CONFIRMATION_SAMPLE).sum()),
        "production_decision": "hold",
        "prospective_test": False,
        "soft_odds_status": "not_available_synchronized",
    }

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    decisions.to_csv(OUTPUT_DIR / "eligible-current-signals.csv", index=False)
    selection_summary.to_csv(OUTPUT_DIR / "selection-filter-grid.csv", index=False)
    confirmation_summary.to_csv(OUTPUT_DIR / "confirmation-summary.csv", index=False)
    all_confirmation_summary.to_csv(
        OUTPUT_DIR / "confirmation-all-registered-filters.csv", index=False
    )
    confirmation_maps.to_csv(OUTPUT_DIR / "confirmation-map-results.csv", index=False)
    bootstrap.to_csv(OUTPUT_DIR / "confirmation-bootstrap.csv", index=False)
    by_league.to_csv(OUTPUT_DIR / "confirmation-by-league.csv", index=False)
    by_side.to_csv(OUTPUT_DIR / "confirmation-by-side.csv", index=False)
    by_month.to_csv(OUTPUT_DIR / "confirmation-by-month.csv", index=False)
    with (OUTPUT_DIR / "decision.json").open("w", encoding="utf-8") as handle:
        json.dump(decision, handle, indent=2, ensure_ascii=False)
    with (OUTPUT_DIR / "run-metadata.json").open("w", encoding="utf-8") as handle:
        json.dump(
            {
                "input": str(INPUT_PATH),
                "registered_live_filters": list(FILTERS),
                "registered_pre_filters": list(PRE_FILTER_IDS),
                "selection_sample": SELECTION_SAMPLE,
                "confirmation_sample": CONFIRMATION_SAMPLE,
                "minimum_selection_bets": MINIMUM_SELECTION_BETS,
                "bootstrap_draws": BOOTSTRAP_DRAWS,
                "seed": RANDOM_SEED,
                "economic_scenarios": {
                    "pinnacle": (
                        "Historical Pinnacle odds at each timing, original 0.5u stake."
                    ),
                    "fictional_soft": (
                        "Only the indicated side receives odds equal to 1.03 divided by "
                        "Pinnacle no-vig probability, fixed 1u stake."
                    ),
                },
            },
            handle,
            indent=2,
            ensure_ascii=False,
        )

    print(selection_summary.to_string(index=False))
    print("\nSelected filters:", selected_filters)
    print(confirmation_summary.to_string(index=False))
    print(bootstrap.to_string(index=False))
    print(by_league.to_string(index=False))


if __name__ == "__main__":
    main()
