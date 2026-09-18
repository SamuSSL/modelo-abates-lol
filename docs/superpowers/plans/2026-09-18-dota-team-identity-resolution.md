# Dota 2 Team Identity and Roster Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Resolver automaticamente a identidade operacional mais recente de cada time Dota por data/evento, mantendo IDs OpenDota distintos, evidência de roster observada e bloqueios explícitos para históricos velhos ou ambíguos.

**Architecture:** Um gerador Python no projeto Dota 2 lê partidas OpenDota detalhadas e o catálogo histórico para produzir um registro versionado de identidades e últimos elencos observados. O adaptador Python do Streamlit carrega esse registro, agrupa nomes iguais em uma opção operacional, resolve o ID point-in-time pelo cutoff e expõe status, idade, roster observado e bloqueios. O modelo de linha permanece inalterado; somente a seleção histórica e a classificação operacional são enriquecidas.

**Tech Stack:** Python 3.12, JSON, pytest, Streamlit testing, OpenDota raw JSON, R apenas como origem das tabelas canônicas.

## Global Constraints

- IDs OpenDota distintos nunca serão fundidos automaticamente.
- Nenhuma evidência posterior ao `scheduled_start` pode influenciar a resolução.
- Roster de partida concluída será chamado `last_observed_roster`, nunca roster futuro confirmado.
- Heróis, draft, side, itens, eventos do mapa e settlement continuam fora das features operacionais.
- `automatic_betting` permanece `false`.
- Arquivos temporários e alterações preexistentes não podem ser incluídos nos commits.

---

### Task 1: Registrar o contrato e criar testes do resolvedor

**Files:**
- Modify: `tests_python/test_dota_synthetic_streamlit.py`
- Create: `tests_python/test_dota_team_identity.py`

**Interfaces:**
- Consumes: `app.dota_team_identity.build_operational_team_catalog`, `resolve_team_identity`, `classify_roster_transition`.
- Produces: casos de teste executáveis para o catálogo agrupado, cutoff, idade, troca de roster e override.

- [x] **Step 1: Write the failing test**

Adicionar testes para:

```python
def test_same_display_name_is_one_operational_team_with_historical_candidates():
    catalog = {"team_history": [
        {"team_id": "old", "team_name": "Hokori", "last_seen": "2026-04-13T00:00:00Z", "map_count": 20},
        {"team_id": "new", "team_name": "Hokori", "last_seen": "2026-06-17T00:00:00Z", "map_count": 8},
    ]}
    rows = build_operational_team_catalog(catalog, {})
    assert len(rows) == 1
    assert rows[0]["canonical_team_name"] == "Hokori"
    assert {row["opendota_team_id"] for row in rows[0]["historical_identities"]} == {"old", "new"}


def test_resolver_never_uses_identity_after_cutoff():
    candidates = [
        {"opendota_team_id": "old", "last_seen": "2026-04-13T00:00:00Z"},
        {"opendota_team_id": "future", "last_seen": "2026-08-01T00:00:00Z"},
    ]
    result = resolve_team_identity(candidates, "2026-06-01T00:00:00Z")
    assert result["opendota_team_id"] == "old"


def test_four_changed_players_create_new_roster_version():
    result = classify_roster_transition([1, 2, 3, 4, 5], [1, 6, 7, 8, 9])
    assert result["overlap_count"] == 1
    assert result["roster_status"] == "new_roster_version"


def test_stale_identity_is_not_approved_for_manual_comparison():
    result = resolve_team_identity(
        [{"opendota_team_id": "old", "last_seen": "2026-04-13T00:00:00Z"}],
        "2026-09-18T00:00:00Z",
    )
    assert result["identity_status"] == "stale"
    assert result["manual_comparison_blocked"] is True
```

- [x] **Step 2: Run test to verify it fails**

Run: `py -3 -m pytest tests_python/test_dota_team_identity.py -q`

Expected: FAIL because `app.dota_team_identity` does not exist.

- [x] **Step 3: Add minimal module skeleton**

Create `app/dota_team_identity.py` with the public function names and `NotImplementedError` bodies. Keep the test failure focused on missing behavior.

- [x] **Step 4: Run test to verify the intended failure**

Run: `py -3 -m pytest tests_python/test_dota_team_identity.py -q`

Expected: FAIL with an assertion or `NotImplementedError` from the new functions, not an import error.

### Task 2: Implement temporal identity and roster transition logic

**Files:**
- Modify: `app/dota_team_identity.py`
- Test: `tests_python/test_dota_team_identity.py`

**Interfaces:**
- `classify_roster_transition(previous_roster: list[str], current_roster: list[str]) -> dict`
- `resolve_team_identity(candidates: list[dict], cutoff: str, approved_event_team_id: str | None = None) -> dict`
- `build_operational_team_catalog(catalog: dict, registry: dict) -> list[dict]`

- [x] **Step 1: Implement normalization and roster classification**

Normalize IDs as strings, calculate set intersection, changed count and statuses:

```text
overlap 5 -> same_roster
overlap 4 -> minor_roster_change
overlap 3 -> partial_roster_change
overlap <=2 -> new_roster_version
missing roster -> unknown
```

- [x] **Step 2: Implement cutoff-safe candidate resolution**

Parse UTC timestamps, discard candidates after cutoff, prefer an approved event ID only when it is eligible before cutoff, otherwise sort by `last_seen` descending. Compute age in days and statuses `fresh`, `aging`, `stale`. Set `manual_comparison_blocked` for `stale`, `ambiguous`, `new_roster_version` or missing evidence.

- [x] **Step 3: Implement grouping by canonical display name**

Group case-insensitively after trimming whitespace, retain every source ID under `historical_identities`, and expose the latest candidate without deleting the historical records.

- [x] **Step 4: Run focused tests**

Run: `py -3 -m pytest tests_python/test_dota_team_identity.py -q`

Expected: all identity tests pass.

### Task 3: Build the OpenDota last-observed-roster registry

**Files:**
- Create: `scripts/74_build_dota_team_identity_registry.py` in `C:\Users\Samuel\Documents\Modelo Abates Dota 2`
- Create: `tests/testthat/test-team-identity-registry.R` only if R-side contract is needed; otherwise use Python tests in the main repo.
- Create: `artifacts/team_identity/dota_team_identity_registry.json` generated by the script.

**Interfaces:**
- Consumes: `data/raw/opendota/*_matches_*.json`, `data/canonical/opendota_matches.csv`, and the source team names.
- Produces: registry rows with source ID, latest observed roster, observation timestamp, map count, and transition status.

- [x] **Step 1: Write the failing roster-transition tests**

The identity test suite feeds two five-player snapshots where four player IDs change and asserts `new_roster_version`; the generated registry is then audited against live/cache payloads.

- [x] **Step 2: Run the identity tests and verify the initial failure**

Run the focused identity test and confirm the roster-transition behavior failed before implementation.

- [x] **Step 3: Implement the generator**

Parse only completed match detail payloads. For each nonzero team ID, collect at most five distinct `account_id` values with `team_number` matching Radiant/Dire. Use `start_time`/`effective_start` as `observed_at`. Do not use `picks_bans`, draft, heroes or post-match features. Keep only the latest roster snapshot per source ID and record prior overlap when available.

- [x] **Step 4: Generate and audit the registry**

Run: `py -3 scripts/74_build_dota_team_identity_registry.py`

Confirm that the output contains no API key, no draft fields and valid UTC timestamps. Report Hokori IDs and their latest observed roster status.

### Task 4: Integrate the registry into the Streamlit adapter

**Files:**
- Modify: `app/dota_synthetic.py`
- Create: `app_data/dota_team_identity_registry.json`
- Modify: `tests_python/test_dota_synthetic_streamlit.py`
- Modify: `tests_python/test_streamlit_interface.py`

**Interfaces:**
- `load_dota_state()` loads the registry when present.
- `build_dota_team_catalog()` returns grouped operational rows while preserving `team_id` compatibility for existing callers.
- `_resolve_automatic_features()` receives the resolved source IDs and returns identity metadata.

- [x] **Step 1: Add failing UI/adapter tests**

Test that the two Hokori IDs become one operational team, that the selected ID for a cutoff after June 17 is `10150267`, that the result metadata includes `identity_status`, and that stale identity sets `manual_comparison_blocked`.

- [x] **Step 2: Run focused tests and confirm failure**

Run: `py -3 -m pytest tests_python/test_dota_synthetic_streamlit.py tests_python/test_streamlit_interface.py -q`

Expected: failures because the current UI still selects raw source IDs and does not load the registry.

- [x] **Step 3: Integrate the resolver**

Load the registry, build one operational option per canonical name, resolve the source ID using the planned start cutoff, and preserve an advanced historical-ID override. Move or compute planned date/time before identity resolution so changing the simulation date changes the selected candidate without future leakage.

- [x] **Step 4: Render identity evidence before calculation**

Show selected ID, last observed date, roster status, overlap count, identity age and manual-comparison block. Keep the result calculation available for research but propagate the block into confidence and decision metadata.

- [x] **Step 5: Run focused tests**

Run: `py -3 -m pytest tests_python/test_dota_synthetic_streamlit.py tests_python/test_streamlit_interface.py -q`

Expected: all focused tests pass.

### Task 5: Validate, document and stage only scoped outputs

**Files:**
- Modify: `docs/dota-synthetic-ev-parity.md`
- Create: `docs/dota-team-identity-resolution.md`
- Modify: `app_data/dota_ui_catalog.json` only if the generated catalog contract needs a version field.

- [x] **Step 1: Document the operational limitation**

Record that `last_observed_roster` is historical evidence, not future roster confirmation, and that PGL or any future event without a verified pre-game roster remains low-confidence.

- [x] **Step 2: Run the complete Python suite**

Run: `py -3 -m pytest tests_python -q`

Expected: no regressions; existing skips and the known dependency warning may remain.

- [x] **Step 3: Run source-side tests**

Run in `C:\Users\Samuel\Documents\Modelo Abates Dota 2`: `& "C:\Program Files\R\R-4.6.1\bin\Rscript.exe" -e "testthat::test_file('tests/testthat/test-team-identity.R')"` and the registry builder compile command.

- [x] **Step 4: Check leakage and secrets**

Run: `rg -n -i "BETTINGISCOOL_API_KEY|key\.txt|api_key|picks_bans|draft_timings" app app_data docs scripts tests_python`

Confirm no secret and no prohibited operational feature was added to the bundle or UI registry.

- [x] **Step 5: Review diff scope**

Run: `git diff --check` and `git status --short`. Stage only identity module, tests, registry, scoped docs and generated app data. Leave `.codex-remote-attachments`, `.playwright-cli`, `1`, `output` and unrelated source-repository changes untouched.
