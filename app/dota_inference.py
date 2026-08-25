from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any


PROHIBITED_FEATURES = {
    "heroes", "picks", "bans", "draft_timings", "composition", "items",
    "events", "duration", "score", "first_blood", "gold", "xp",
    "closing_line", "closing_odds", "side", "radiant", "dire",
}


class BundleError(ValueError):
    pass


def load_bundle(path: str | Path) -> dict[str, Any]:
    bundle = json.loads(Path(path).read_text(encoding="utf-8"))
    target = bundle.get("target_contract", {})
    if target.get("prediction_stage") != "pre_draft":
        raise BundleError("Bundle is not pre-draft.")
    if target.get("automatic_betting") is not False:
        raise BundleError("Automatic betting must remain disabled.")
    names = {str(item) for item in bundle.get("feature_names", [])}
    leakage = names.intersection(PROHIBITED_FEATURES)
    if leakage:
        raise BundleError(f"Bundle contains prohibited features: {sorted(leakage)}")
    return bundle


def _ridge_predict(model: dict[str, Any], features: dict[str, Any]) -> float:
    names = model.get("feature_names", [])
    beta = model.get("beta", [])
    preprocessor = model.get("preprocessor", {})
    centers = preprocessor.get("center", {})
    scales = preprocessor.get("scale", {})
    columns = [1.0]
    missing = []
    for name in names:
        raw = features.get(name)
        try:
            value = float(raw)
            is_missing = not math.isfinite(value)
        except (TypeError, ValueError):
            value = float("nan")
            is_missing = True
        center = float(centers.get(name, 0.0) or 0.0)
        scale = float(scales.get(name, 1.0) or 1.0)
        if not math.isfinite(scale) or scale <= 0:
            scale = 1.0
        if is_missing:
            value = center
        columns.append((value - center) / scale)
        missing.append(1.0 if is_missing else 0.0)
    columns.extend(missing)
    return sum(float(coefficient) * value for coefficient, value in zip(beta, columns))


def _baseline_predict(model: dict[str, Any], features: dict[str, Any], field: str) -> float:
    component = model.get(field, {})
    group = str(features.get(model.get("group_feature", "competition_id"), ""))
    groups = component.get("groups", {})
    return float(groups.get(group, component.get("global", 0.0)))


def predict(bundle: dict[str, Any], features: dict[str, Any]) -> dict[str, Any]:
    model = bundle.get("market_model")
    blocks = ["automatic_betting_disabled"]
    if bundle.get("status") != "approved_for_manual_soft_comparison" or not model:
        blocks.append("no_promoted_model")
        return {
            "status": "blocked",
            "prediction": None,
            "confidence": "blocked",
            "blocks": blocks,
            "automatic_betting_approved": False,
        }
    if model.get("type") == "league_baseline":
        line = _baseline_predict(model, features, "line")
        probability = _baseline_predict(model, features, "probability")
    elif model.get("type") == "ridge":
        line = _ridge_predict(model["line"], features)
        probability = _ridge_predict(model["probability"], features)
    else:
        raise BundleError(f"Unsupported market model type: {model.get('type')}")
    probability = min(max(probability, 1e-6), 1 - 1e-6)
    interval = float(model.get("line_interval_half_width", 2.0))
    return {
        "status": "ready_for_manual_soft_comparison",
        "line": line,
        "line_interval": {"lower": line - interval, "upper": line + interval},
        "probability_over": probability,
        "probability_under": 1.0 - probability,
        "fair_odds_over": 1.0 / probability,
        "fair_odds_under": 1.0 / (1.0 - probability),
        "ev": None,
        "confidence": "model_only",
        "blocks": blocks,
        "automatic_betting_approved": False,
    }
