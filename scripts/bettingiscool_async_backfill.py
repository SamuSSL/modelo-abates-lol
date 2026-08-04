from __future__ import annotations

import concurrent.futures
import argparse
import hashlib
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RAW_ROOT = ROOT / "data" / "raw" / "bettingiscool"
BASE_URL = "https://api.bettingiscool.com"
API_KEY = os.environ.get("BETTINGISCOOL_API_KEY", "")
QUOTA_RESERVE = int(os.environ.get("BETTINGISCOOL_QUOTA_RESERVE", "1000"))
WORKERS = int(os.environ.get("BETTINGISCOOL_WORKERS", "5"))
quota_lock = threading.Lock()
minimum_quota = float("inf")
quota_stop = threading.Event()


def canonical_query(query: dict[str, object]) -> str:
    return json.dumps(query, sort_keys=True, separators=(",", ":"))


def request_id(endpoint: str, query: dict[str, object]) -> str:
    value = f"{endpoint}|{canonical_query(query)}"
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def endpoint_directory(endpoint: str) -> Path:
    name = endpoint.strip("/").lower().replace("/", "_")
    directory = RAW_ROOT / name
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def completed_requests() -> set[str]:
    completed: set[str] = set()
    for path in RAW_ROOT.glob("api_*/*.meta.json"):
        try:
            metadata = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        endpoint = metadata.get("endpoint")
        query = metadata.get("query")
        if endpoint and isinstance(query, dict):
            completed.add(request_id(endpoint, query))
    return completed


def fixture_event_ids() -> list[int]:
    event_ids: set[int] = set()
    fixture_dir = RAW_ROOT / "api_fixtures"
    for path in fixture_dir.glob("*.json"):
        if path.name.endswith(".meta.json"):
            continue
        try:
            rows = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(rows, list):
            continue
        for row in rows:
            if row.get("resulting_unit") == "Kills":
                event_ids.add(int(row["event_id"]))
    return sorted(event_ids)


def atomic_write(path: Path, content: str) -> None:
    temporary = path.with_suffix(path.suffix + f".{threading.get_ident()}.tmp")
    temporary.write_text(content, encoding="utf-8")
    os.replace(temporary, path)


def fetch(task: tuple[str, dict[str, object]]) -> tuple[str, int, float]:
    global minimum_quota
    if quota_stop.is_set():
        return "", 0, minimum_quota
    endpoint, query = task
    query_string = urllib.parse.urlencode(query)
    url = f"{BASE_URL}{endpoint}?{query_string}"
    request = urllib.request.Request(
        url,
        headers={
            "X-API-Key": API_KEY,
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 lolkills-research",
        },
    )
    last_error: Exception | None = None
    for attempt in range(1, 6):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                body = response.read()
                status = response.status
                headers = {key.lower(): value for key, value in response.headers.items()}
            break
        except urllib.error.HTTPError as error:
            last_error = error
            if error.code not in (403, 429) and error.code < 500:
                raise
            retry_after = float(error.headers.get("Retry-After", 2 ** (attempt - 1)))
            time.sleep(min(retry_after, 30))
        except OSError as error:
            last_error = error
            time.sleep(min(2 ** (attempt - 1), 30))
    else:
        raise RuntimeError(f"Request failed after retries: {endpoint}") from last_error

    text = body.decode("utf-8")
    raw_sha256 = hashlib.sha256(body).hexdigest()
    directory = endpoint_directory(endpoint)
    body_path = directory / f"{raw_sha256}.json"
    metadata_path = directory / f"{request_id(endpoint, query)}.meta.json"
    if not body_path.exists():
        atomic_write(body_path, text)

    quota_remaining = float(headers.get("x-quota-remaining", "nan"))
    quota_cost = float(headers.get("x-quota-cost", "nan"))
    row_count = int(headers.get("x-rows", "0"))
    truncated = headers.get("x-truncated", "false").lower() == "true"
    metadata = {
        "endpoint": endpoint,
        "query": query,
        "retrieved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "status_code": status,
        "quota_remaining": quota_remaining,
        "quota_cost": quota_cost,
        "row_count": row_count,
        "truncated": truncated,
        "sha256": raw_sha256,
        "request_sha256": request_id(endpoint, query),
    }
    if not metadata_path.exists():
        atomic_write(
            metadata_path,
            json.dumps(metadata, ensure_ascii=False, indent=2),
        )
    with quota_lock:
        minimum_quota = min(minimum_quota, quota_remaining)
        if truncated or quota_remaining < QUOTA_RESERVE:
            quota_stop.set()
    return endpoint, row_count, quota_remaining


def build_tasks(
    events: list[int],
    mode: str,
) -> list[tuple[str, dict[str, object]]]:
    tasks: list[tuple[str, dict[str, object]]] = []
    for event_id in events:
        if mode == "kills_totals":
            specifications = (
                (
                    "/api/odds",
                    {
                        "event_id": event_id,
                        "market": "totals",
                        "full_history": 1,
                        "main_lines_only": 1,
                    },
                ),
                ("/api/opening", {"event_id": event_id, "market": "totals"}),
                ("/api/closing", {"event_id": event_id, "market": "totals"}),
                ("/api/results", {"event_id": event_id}),
            )
        elif mode == "team_totals_coverage":
            specifications = tuple(
                (endpoint, {"event_id": event_id, "market": market})
                for market in ("home_totals", "away_totals")
                for endpoint in ("/api/opening", "/api/closing")
            )
        else:
            specifications = tuple(
                (
                    "/api/odds",
                    {
                        "event_id": event_id,
                        "market": market,
                        "full_history": 1,
                        "main_lines_only": 1,
                    },
                )
                for market in ("home_totals", "away_totals")
            )
        tasks.extend(specifications)
    return tasks


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=(
            "kills_totals",
            "team_totals_coverage",
            "team_totals_history",
        ),
        default="kills_totals",
    )
    arguments = parser.parse_args()
    if not API_KEY:
        raise SystemExit("Set BETTINGISCOOL_API_KEY before the backfill.")
    events = fixture_event_ids()
    completed = completed_requests()
    if arguments.mode == "team_totals_history":
        events = sorted(
            events,
            key=lambda event_id: hashlib.sha256(
                str(event_id).encode("utf-8")
            ).hexdigest(),
        )
    all_tasks = build_tasks(events, arguments.mode)
    tasks = [
        task
        for task in all_tasks
        if request_id(task[0], task[1]) not in completed
    ]

    endpoint_counts: dict[str, int] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as executor:
        futures = [executor.submit(fetch, task) for task in tasks]
        for index, future in enumerate(
            concurrent.futures.as_completed(futures),
            start=1,
        ):
            endpoint, _, _ = future.result()
            if not endpoint:
                continue
            endpoint_counts[endpoint] = endpoint_counts.get(endpoint, 0) + 1
            if index % 250 == 0:
                print(
                    f"completed={index}/{len(tasks)} "
                    f"quota_remaining={minimum_quota:.0f}",
                    flush=True,
                )
    print(
        json.dumps(
            {
                "mode": arguments.mode,
                "events": len(events),
                "requests_completed": len(tasks),
                "endpoint_counts": endpoint_counts,
                "quota_remaining": minimum_quota,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
