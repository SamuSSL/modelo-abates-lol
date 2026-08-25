# Dota 2 Additional Synthetic Quotes Implementation Plan

> For agentic workers: use executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

Goal: Adicionar ao HUD de Dota 2 as cotações sintéticas opcionais 2 e 3, reproduzindo o fluxo de comparação manual do LoL.

Architecture: A aba Dota construirá uma lista de uma a três cotações a partir da cotação principal e dos checkboxes opcionais. A predição existente será executada uma vez para cada cotação, sem modificar as features ou o bundle; a sessão exibirá os resultados alinhados por slot.

Tech Stack: Python, Streamlit, streamlit.testing.v1.AppTest, pytest.

## Global Constraints

- Preservar o contrato Dota pré-draft e as oito features automáticas.
- Não usar linha, odds ou casa soft como feature.
- Manter automatic_betting_approved: false.
- Não alterar o fluxo do LoL.
- Manter validação de half-lines e odds maiores que 1.00.

---

### Task 1: Test contract for optional Dota quotes

Files:
- Modify: tests_python/test_streamlit_pinnacle_tabs.py
- Modify: tests_python/test_dota_synthetic_streamlit.py

Interfaces:
- Consumes: current render_dota_tab and predict_dota_quote behavior.
- Produces: regression coverage for the two optional quote selectors and multi-quote prediction payloads.

- [ ] Step 1: Write the failing interface test

Add assertions that the Dota tab exposes the two optional quote selectors. Add a unit assertion that a helper or assembled quote payload can represent slots 1, 2, and 3 while retaining each bookmaker, line, and pair of odds.

- [ ] Step 2: Run the focused tests to verify the new expectation fails

Run:

~~~powershell
py -3 -m pytest tests_python/test_streamlit_pinnacle_tabs.py tests_python/test_dota_synthetic_streamlit.py -q
~~~

Expected: the new selector assertion fails because the Dota HUD currently renders only the primary quote.

### Task 2: Implement optional quote inputs and per-quote results

Files:
- Modify: app/dota_synthetic.py
- Modify: tests_python/test_streamlit_pinnacle_tabs.py
- Modify: tests_python/test_dota_synthetic_streamlit.py

Interfaces:
- Consumes: existing predict_dota_quote(state, features, soft_quote) function.
- Produces: a Dota form with additional_quotes, one result per active quote, and session payload containing all quote inputs and predictions.

- [ ] Step 1: Add the minimal quote assembly helper

Create a small pure helper that receives the primary quote and optional quote rows and returns normalized quote dictionaries with slot values 1, 2, and 3. It must preserve bookmaker, line, odds_over, and odds_under.

- [ ] Step 2: Run the focused test and confirm the helper contract passes

Run:

~~~powershell
py -3 -m pytest tests_python/test_dota_synthetic_streamlit.py -q
~~~

- [ ] Step 3: Add the two checkboxes and conditional four-field rows

Render the same labels and keys used by the LoL synthetic flow, namespaced with dota_. Keep the primary row unchanged. Reject an enabled additional quote with an empty bookmaker before prediction.

- [ ] Step 4: Calculate each active quote independently

Build the normalized list and call predict_dota_quote once for each row. Store quotes and predictions together in st.session_state["dota_last_result"]; retain the first prediction as the headline result for backward-compatible metrics.

- [ ] Step 5: Render the per-quote comparison

Render one section per active quote with slot, bookmaker, line, fair odds, EV when the line matches, and the existing mismatch warning when it does not. Keep automatic betting disabled.

- [ ] Step 6: Run the focused tests and fix only implementation failures

Run:

~~~powershell
py -3 -m pytest tests_python/test_streamlit_pinnacle_tabs.py tests_python/test_dota_synthetic_streamlit.py -q
~~~

Expected: all focused tests pass.

### Task 3: Full verification and handoff

Files:
- Inspect: app/dota_synthetic.py
- Inspect: tests_python/test_streamlit_pinnacle_tabs.py
- Inspect: tests_python/test_dota_synthetic_streamlit.py

Interfaces:
- Consumes: completed multi-quote Dota HUD.
- Produces: verified local change ready for commit/push.

- [ ] Step 1: Run the complete Python test suite

Run:

~~~powershell
py -3 -m pytest tests_python -q
~~~

- [ ] Step 2: Compile the modified Python modules

Run:

~~~powershell
py -3 -m py_compile app/dota_synthetic.py tests_python/test_dota_synthetic_streamlit.py tests_python/test_streamlit_pinnacle_tabs.py
~~~

- [ ] Step 3: Review the diff and secret scope

Run:

~~~powershell
git diff --check
git diff -- app/dota_synthetic.py tests_python/test_dota_synthetic_streamlit.py tests_python/test_streamlit_pinnacle_tabs.py docs/superpowers/specs/2026-08-25-dota-additional-synthetic-quotes-design.md docs/superpowers/plans/2026-08-25-dota-additional-synthetic-quotes.md
~~~

Confirm that only the Dota HUD, its tests, and the design/plan documents changed, with no secrets or generated artifacts staged.
