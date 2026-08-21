# Synthetic Pinnacle Interface and Weekly Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose only the synthetic pre-opening Pinnacle workflow and provide one manual weekly updater that trains, validates, publishes, and reports that synthetic bundle.

**Architecture:** `app/vault_streamlit.py` will route every public visit directly to the synthetic calculator without database persistence. A new PowerShell orchestrator will validate and replace the Oracle CSV, refresh R and BettingIsCool inputs, train `synthetic_pinnacle_bundle.json`, test it, publish it, and leave a dated report.

**Tech Stack:** Python/Streamlit, R with renv, DuckDB, PowerShell, Git, GitHub, Streamlit Community Cloud.

## Global Constraints

- Preserve existing source lines; bypass retired UI paths rather than deleting their definitions.
- The public model artifact is `app_data/synthetic_pinnacle_bundle.json`.
- Do not write credentials, API keys, passwords, or connection strings to source files or reports.
- The updater reads `BETTINGISCOOL_API_KEY` only from the current process environment.
- A weekly publish stages only `app_data/synthetic_pinnacle_bundle.json`.
- `Deu tudo certo!` is written only after every required stage succeeds.
- A Streamlit health response proves reachability, not the exact deployed bundle version.

---

### Task 1: Restrict the public interface to synthetic Pinnacle

**Files:**

- Modify: `app/vault_streamlit.py` in the hero, startup, and `run_vault_app` routing areas.
- Modify: `tests_python/test_streamlit_interface.py`.

**Interfaces:**

- Consumes: `app_data/synthetic_pinnacle_bundle.json` through `load_synthetic_pinnacle_bundle()`.
- Produces: `run_vault_app()` with no visible navigation and no database dependency for the synthetic calculation.

- [ ] **Step 1: Write failing interface tests**

```python
def test_streamlit_opens_directly_in_synthetic_pinnacle_without_navigation():
    app = AppTest.from_file("streamlit_app.py", default_timeout=20).run()
    assert len(app.exception) == 0
    assert any(title.value == "Pinnacle sintética pré-abertura" for title in app.title)
    assert not app.radio
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `python -m pytest tests_python/test_streamlit_interface.py -q`

Expected: the radio navigation is still present.

- [ ] **Step 3: Implement the minimal routing change**

Keep old rendering functions. Make `run_vault_app()` call `_render_synthetic_pinnacle()` directly, change hero copy to synthetic pre-opening language, and bypass synthetic writes to `save_soft_quote_observation()` and `save_pinnacle_forecast()`.

- [ ] **Step 4: Replace incompatible legacy tests**

Keep synthetic-calculation tests. Replace tests that expect retired tabs, post-draft controls, persistence, or fallback with assertions that their labels are absent.

- [ ] **Step 5: Run focused tests and commit**

Run: `python -m pytest tests_python/test_streamlit_interface.py tests_python/test_synthetic_pinnacle.py -q`

Commit: `git add app/vault_streamlit.py tests_python/test_streamlit_interface.py; git commit -m "feat: focus public app on synthetic Pinnacle"`

### Task 2: Add the weekly synthetic updater

**Files:**

- Create: `scripts/atualizar_pinnacle_sintetica.ps1`.
- Create: `tests_python/test_weekly_synthetic_updater.py`.
- Modify: `.gitignore` to exclude `Relatórios de atualização/`.

**Interfaces:**

- Consumes: Google Drive file id `1hnpbrUpBMS1TZI7IovfpKeZfWJH1Aptm`, R executable, `BETTINGISCOOL_API_KEY`, and `origin/main`.
- Produces: a dated report in `Relatórios de atualização/` and a Git commit containing only `app_data/synthetic_pinnacle_bundle.json`.

- [ ] **Step 1: Write failing updater tests**

```python
def test_updater_writes_failure_report_when_api_key_is_missing(tmp_path):
    completed = run_updater(tmp_path, "-SkipDownload", "-NoPublish")
    assert completed.returncode != 0
    report = newest_report(tmp_path / "Relatórios de atualização")
    assert "BETTINGISCOOL_API_KEY" in report.read_text(encoding="utf-8")
    assert "Deu tudo certo!" not in report.read_text(encoding="utf-8")
```

- [ ] **Step 2: Run the tests and verify they fail because the script is absent**

Run: `python -m pytest tests_python/test_weekly_synthetic_updater.py -q`

Expected: missing updater script.

- [ ] **Step 3: Implement validated download and reporting primitives**

Implement `Write-Stage`, `Write-FailureReport`, `Invoke-RScript`, `Get-FileSha256`, `Invoke-DownloadOracleCsv`, and `Publish-SyntheticBundle`. Download into a temporary sibling path, reject HTML/login responses, require a CSV header, require a SHA-256 different from the active 2026 file, and only then replace the active raw file.

- [ ] **Step 4: Implement the ordered data and model pipeline**

Run these scripts in order, stopping on the first error: `01_register_raw_data.R`, `02_audit_and_normalize.R`, `03_build_canonical_games.R`, `04_write_processed_store.R`, `07_build_team_metrics.R`, `09_build_rolling_team_features.R`, `10_build_map_feature_table.R`, `14_build_player_draft_audit.R`, `62_build_premap_ratio_features.R`, `51_collect_bettingiscool_odds.R`, `52_match_bettingiscool_games.R`, and `124_train_synthetic_pinnacle_direct_market.R`.

- [ ] **Step 5: Implement validation and scoped publication**

Run `scripts/99_run_full_tests.R` and `python -m pytest tests_python -q`. Require a changed synthetic bundle, stage exactly that path, commit, push to `origin main`, compare the GitHub raw bundle hash to the local hash, then poll the Streamlit health endpoint. Record GitHub confirmation and Streamlit reachability separately. End the report with `Deu tudo certo!` only after both pass.

- [ ] **Step 6: Run updater tests and commit**

Run: `python -m pytest tests_python/test_weekly_synthetic_updater.py -q`

Commit: `git add scripts/atualizar_pinnacle_sintetica.ps1 tests_python/test_weekly_synthetic_updater.py .gitignore; git commit -m "feat: add weekly synthetic Pinnacle updater"`

### Task 3: Document and verify the integrated workflow

**Files:**

- Modify: `docs/deployment.md` in its active-interface and persistence sections.
- Test: Python, R, and updater suites.

**Interfaces:**

- Consumes: completed Tasks 1 and 2.
- Produces: a documented synthetic-only application and ready-to-run weekly command.

- [ ] **Step 1: Add a failing documentation assertion**

```python
def test_deployment_documentation_names_synthetic_bundle_as_public_artifact():
    documentation = Path("docs/deployment.md").read_text(encoding="utf-8")
    assert "app_data/synthetic_pinnacle_bundle.json" in documentation
    assert "Pinnacle sintética pré-abertura" in documentation
```

- [ ] **Step 2: Run it and verify it fails against the old document**

Run: `python -m pytest tests_python/test_weekly_synthetic_updater.py -q`

Expected: active documentation still describes the post-draft workflow.

- [ ] **Step 3: Update the deployment document**

Describe the synthetic bundle, updater command, report location, environment-variable requirement, and the difference between GitHub publication and Streamlit health verification. Preserve historical persistence documentation as retired context.

- [ ] **Step 4: Run full verification and commit**

Run: `& "C:\Program Files\R\R-4.6.1\bin\Rscript.exe" scripts/99_run_full_tests.R; python -m pytest tests_python -q; git diff --check`

Commit: `git add docs/deployment.md tests_python/test_weekly_synthetic_updater.py; git commit -m "docs: describe synthetic weekly release workflow"`

## Plan self-review

- Task 1 covers every approved UI and persistence removal.
- Task 2 covers download, data update, training, validation, report, scoped commit, push, and publishing evidence.
- Task 3 keeps the active documentation aligned and verifies all test suites.
