from __future__ import annotations

import json
from pathlib import Path
import sys

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
    / "current-confiometer-backtest"
)
RANDOM_SEED = 20260805
BOOTSTRAP_DRAWS = 2000


def probability_over(mean: float, theta: float, line: float) -> float:
    pmf = negative_binomial_pmf(float(mean), float(theta))
    threshold = int(np.floor(float(line)))
    return 1.0 - float(sum(pmf[: threshold + 1]))


def settle(side: str | None, observed: float, line: float, odds: float, stake: float) -> float:
    if side is None or stake <= 0:
        return 0.0
    won = observed > line if side == "over" else observed < line
    return stake * (odds - 1.0) if won else -stake


def maximum_drawdown(profits: pd.Series) -> float:
    cumulative = profits.cumsum()
    running_peak = cumulative.cummax().clip(lower=0.0)
    return float((running_peak - cumulative).max()) if len(profits) else 0.0


def summarize(frame: pd.DataFrame, test_id: str) -> dict[str, float | int | str | None]:
    acted = frame.loc[frame["recommended_stake"] > 0].copy()
    total_stake = float(acted["recommended_stake"].sum())
    profit = float(acted["profit_units"].sum())
    return {
        "test_id": test_id,
        "maps": int(len(frame)),
        "bets": int(len(acted)),
        "abstentions": int(len(frame) - len(acted)),
        "over_bets": int((acted["recommended_side"] == "over").sum()),
        "under_bets": int((acted["recommended_side"] == "under").sum()),
        "stake_units": total_stake,
        "wins": int((acted["profit_units"] > 0).sum()),
        "losses": int((acted["profit_units"] < 0).sum()),
        "hit_rate": float((acted["profit_units"] > 0).mean()) if len(acted) else None,
        "profit_units": profit,
        "yield": profit / total_stake if total_stake > 0 else None,
        "maximum_drawdown": maximum_drawdown(acted["profit_units"]),
    }


def bootstrap_by_series(frame: pd.DataFrame, test_id: str) -> dict[str, float | int | str | None]:
    acted = frame.loc[frame["recommended_stake"] > 0].copy()
    grouped = acted.groupby("series_id", sort=False)[
        ["profit_units", "recommended_stake"]
    ].sum()
    if grouped.empty:
        return {
            "test_id": test_id,
            "series": 0,
            "draws": BOOTSTRAP_DRAWS,
            "yield_lower_95": None,
            "yield_upper_95": None,
            "probability_positive_yield": None,
        }
    rng = np.random.default_rng(RANDOM_SEED)
    values = grouped.to_numpy(dtype=float)
    sampled_yields = np.empty(BOOTSTRAP_DRAWS, dtype=float)
    for draw in range(BOOTSTRAP_DRAWS):
        indices = rng.integers(0, len(values), size=len(values))
        sample = values[indices]
        sampled_yields[draw] = sample[:, 0].sum() / sample[:, 1].sum()
    return {
        "test_id": test_id,
        "series": int(len(grouped)),
        "draws": BOOTSTRAP_DRAWS,
        "yield_lower_95": float(np.quantile(sampled_yields, 0.025)),
        "yield_upper_95": float(np.quantile(sampled_yields, 0.975)),
        "probability_positive_yield": float((sampled_yields > 0).mean()),
    }


def evaluate_row(row: pd.Series) -> tuple[dict[str, object], dict[str, object]]:
    structural_probability_over = probability_over(
        row["structural_mean"],
        row["structural_theta"],
        row["live_line"],
    )
    structural = {
        "probability_over": structural_probability_over,
        "probability_under": 1.0 - structural_probability_over,
        "mean": float(row["structural_mean"]),
    }
    pinnacle = {
        "probability_over_soft": float(row["market_probability_over"]),
        "probability_under_soft": 1.0 - float(row["market_probability_over"]),
        "mean": float(row["market_mean"]),
    }
    actual_request = {
        "soft_odds_over": float(row["live_odds_over"]),
        "soft_odds_under": float(row["live_odds_under"]),
    }
    actual = evaluate_model_agreement(actual_request, structural, pinnacle)
    actual_side = actual.get("recommended_side")
    actual_stake = float(actual.get("recommended_stake") or 0.0)
    actual_odds = (
        float(row[f"live_odds_{actual_side}"])
        if actual_side is not None
        else 0.0
    )
    actual_result = {
        "status": actual["status"],
        "recommended_side": actual_side,
        "recommended_stake": actual_stake,
        "offered_odds": actual_odds,
        "profit_units": settle(
            actual_side,
            float(row["observed_total"]),
            float(row["live_line"]),
            actual_odds,
            actual_stake,
        ),
    }

    if actual_side is None:
        fictional_result = {
            "status": "no_side_indicated",
            "recommended_side": None,
            "recommended_stake": 0.0,
            "offered_odds": 0.0,
            "profit_units": 0.0,
        }
        return actual_result, fictional_result

    fictional_odds = 1.03 / float(
        pinnacle[f"probability_{actual_side}_soft"]
    )
    fictional_request = dict(actual_request)
    fictional_request[f"soft_odds_{actual_side}"] = fictional_odds
    fictional = evaluate_model_agreement(
        fictional_request,
        structural,
        pinnacle,
    )
    fictional_side = fictional.get("recommended_side")
    fictional_stake = float(fictional.get("recommended_stake") or 0.0)
    fictional_offered_odds = (
        float(fictional_request[f"soft_odds_{fictional_side}"])
        if fictional_side is not None
        else 0.0
    )
    fictional_result = {
        "status": fictional["status"],
        "recommended_side": fictional_side,
        "recommended_stake": fictional_stake,
        "offered_odds": fictional_offered_odds,
        "profit_units": settle(
            fictional_side,
            float(row["observed_total"]),
            float(row["live_line"]),
            fictional_offered_odds,
            fictional_stake,
        ),
    }
    return actual_result, fictional_result


def main() -> None:
    data = pd.read_csv(INPUT_PATH)
    required = [
        "gameid",
        "series_id",
        "game_datetime",
        "league_canonical",
        "observed_total",
        "live_line",
        "live_odds_over",
        "live_odds_under",
        "structural_mean",
        "structural_theta",
        "market_probability_over",
        "market_mean",
    ]
    data = data.dropna(subset=required).copy()
    data["game_datetime"] = pd.to_datetime(data["game_datetime"], utc=True)
    data = data.sort_values(["game_datetime", "gameid"]).reset_index(drop=True)

    actual_rows: list[dict[str, object]] = []
    fictional_rows: list[dict[str, object]] = []
    identity = [
        "gameid",
        "series_id",
        "game_datetime",
        "league_canonical",
        "observed_total",
        "live_line",
    ]
    for _, row in data.iterrows():
        actual, fictional = evaluate_row(row)
        base = {name: row[name] for name in identity}
        actual_rows.append({**base, **actual, "test_id": "pinnacle_live_execution"})
        fictional_rows.append({**base, **fictional, "test_id": "fictional_3pct_ev"})

    evaluated = pd.concat(
        [pd.DataFrame(actual_rows), pd.DataFrame(fictional_rows)],
        ignore_index=True,
    )
    summaries = []
    bootstraps = []
    league_summaries = []
    status_summaries = []
    for test_id, frame in evaluated.groupby("test_id", sort=False):
        frame = frame.sort_values(["game_datetime", "gameid"])
        summaries.append(summarize(frame, test_id))
        bootstraps.append(bootstrap_by_series(frame, test_id))
        for league, league_frame in frame.groupby("league_canonical"):
            row = summarize(league_frame, test_id)
            row["league_canonical"] = league
            league_summaries.append(row)
        for status, status_frame in frame.groupby("status"):
            status_summaries.append(
                {
                    "test_id": test_id,
                    "status": status,
                    "maps": int(len(status_frame)),
                    "bets": int((status_frame["recommended_stake"] > 0).sum()),
                    "stake_units": float(status_frame["recommended_stake"].sum()),
                    "profit_units": float(status_frame["profit_units"].sum()),
                }
            )

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    evaluated.to_csv(OUTPUT_DIR / "map-results.csv", index=False)
    pd.DataFrame(summaries).to_csv(OUTPUT_DIR / "overall-summary.csv", index=False)
    pd.DataFrame(league_summaries).to_csv(OUTPUT_DIR / "by-league.csv", index=False)
    pd.DataFrame(status_summaries).to_csv(OUTPUT_DIR / "by-status.csv", index=False)
    pd.DataFrame(bootstraps).to_csv(OUTPUT_DIR / "bootstrap-by-series.csv", index=False)
    with (OUTPUT_DIR / "run-metadata.json").open("w", encoding="utf-8") as handle:
        json.dump(
            {
                "input": str(INPUT_PATH),
                "eligible_maps": len(data),
                "bootstrap_draws": BOOTSTRAP_DRAWS,
                "seed": RANDOM_SEED,
                "test_1": "Current confiometer using Pinnacle live odds as execution odds.",
                "test_2": (
                    "Only the side indicated in test 1 receives fictional odds "
                    "equal to 1.03 divided by Pinnacle no-vig probability; the "
                    "current confiometer is then evaluated again."
                ),
            },
            handle,
            indent=2,
            ensure_ascii=False,
        )
    print(pd.DataFrame(summaries).to_string(index=False))
    print(pd.DataFrame(bootstraps).to_string(index=False))
    print(pd.DataFrame(league_summaries).to_string(index=False))


if __name__ == "__main__":
    main()
