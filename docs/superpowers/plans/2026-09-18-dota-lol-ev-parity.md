# Dota 2/LoL EV Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Dota 2 synthetic Pinnacle tab calculate and display soft-book EV exactly like the LoL synthetic flow, even when the soft-book line differs from the predicted line.

**Architecture:** Preserve the Dota-specific feature resolver and market bundle, but adapt its quote calculation to the same line-aware direct-market contract used by `app/synthetic_pinnacle.py`. Extend the Dota bundle with the market slope, price residual interval, and conservative EV threshold needed by that contract. Render the same result fields for each independent soft quote while keeping automatic betting disabled.

**Tech Stack:** Python 3, Streamlit, pytest, R bundle builder, JSON portable bundle, CSV BettingIsCool artifacts.

## Global Constraints

- Dota remains `pre_draft`, `side_agnostic`, and `automatic_betting_approved: false`.
- The soft-book line and odds are quote inputs only; they never become model features.
- OpenDota remains the historical feature source and BettingIsCool remains the Pinnacle/market source.
- Preserve all unrelated user changes in both repositories.
- Do not store or expose the BettingIsCool API key.

---

### Task 1: Add failing parity tests

**Files:**
- Modify: `C:/Users/Samuel/Documents/Modelo Abates LoL/tests_python/test_dota_synthetic_streamlit.py`

**Interfaces:**
- Consumes: `load_dota_state`, `predict_dota_quote`, `build_dota_quotes`.
- Produces: executable regression coverage for the Dota quote contract.

- [x] **Step 1: Write failing tests**

Add tests asserting that a soft line above and below the predicted line still returns finite point and conservative EV values, that a higher soft line decreases the Over probability, and that all three quote slots have independent outputs. Add required keys for `conservative_ev_over`, `conservative_ev_under`, `recommended_side`, `action`, `predicted_final_line`, `predicted_final_odds_over`, and `automatic_betting_approved`.

- [x] **Step 2: Run the focused tests**

Run:

```powershell
py -3 -m pytest tests_python/test_dota_synthetic_streamlit.py -q
```

Expected: the new parity tests fail because the current adapter returns `None` for mismatched-line EV and lacks the LoL quote fields.

### Task 2: Extend the Dota bundle contract

**Files:**
- Modify: `C:/Users/Samuel/Documents/Modelo Abates Dota 2/scripts/50_build_bundle.R`
- Modify: `C:/Users/Samuel/Documents/Modelo Abates Dota 2/R/models_market.R` only if a reusable slope helper is needed.
- Create: `C:/Users/Samuel/Documents/Modelo Abates Dota 2/tests/testthat/test-bundle-contract.R`
- Modify: `C:/Users/Samuel/Documents/Modelo Abates LoL/app_data/dota2_pinnacle_pre_draft_bundle.json` through the reproducible builder output.

**Interfaces:**
- Consumes: canonical market targets, BettingIsCool movement history, OOF direct probability predictions.
- Produces: `market_probability_logit_slope_per_kill`, `line_model.residual_interval`, `price_model.residual_logit_interval`, and `minimum_conservative_ev` in the Dota bundle.

- [x] **Step 1: Add a failing contract assertion**

Assert that a promoted Dota bundle contains the four new fields and that the slope is finite and positive.

- [x] **Step 2: Run the contract test**

Run `& 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' -e "testthat::test_file('tests/testthat/test-models.R')"` and confirm failure against the current bundle if the contract assertion is added.

- [x] **Step 3: Implement bundle derivation**

Derive the positive slope from within-event BettingIsCool line movements using the negative slope of `logit(no_vig_over)` against the half-line. Derive the signed price-logit interval from out-of-fold actual versus direct probability predictions. Preserve the derivation method and counts in bundle provenance. Set the conservative EV threshold to the same operational threshold used by the LoL direct-market bundle.

- [x] **Step 4: Rebuild the Dota bundle**

Run the existing Dota bundle build from the Dota repository, copy only the resulting portable bundle into the LoL app data path, and verify no secret reference is present.

- [x] **Step 5: Run bundle tests**

Run `& 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe' -e "testthat::test_file('tests/testthat/test-models.R')"` and the Python bundle tests. Expected: the model and adapter tests pass.

### Task 3: Implement the line-aware Dota quote contract

**Files:**
- Modify: `C:/Users/Samuel/Documents/Modelo Abates LoL/app/dota_inference.py`
- Modify: `C:/Users/Samuel/Documents/Modelo Abates LoL/app/dota_synthetic.py`

**Interfaces:**
- Consumes: the promoted Dota bundle and one Dota feature snapshot.
- Produces: one LoL-compatible quote result per soft-book quote.

- [x] **Step 1: Implement the smallest failing-compatible path**

Use the existing Dota line and probability predictions as the model point, convert the probability to logit, shift it by the bundle slope and soft-line difference, and calculate point EV, conservative EV, fair odds, no-vig soft probability, confidence, recommended side, action, and predicted final price fields using the same formulas as the LoL direct-market implementation.

- [x] **Step 2: Remove the mismatch block**

Replace the current `same_line`/`line_mismatch` branch with line-aware calculation. Preserve input validation for `.5` lines and odds greater than `1.00`.

- [x] **Step 3: Verify focused Python tests**

Run:

```powershell
py -3 -m pytest tests_python/test_dota_synthetic_streamlit.py -q
```

Expected: all Dota adapter tests pass.

### Task 4: Match the Streamlit result surface

**Files:**
- Modify: `C:/Users/Samuel/Documents/Modelo Abates LoL/app/dota_synthetic.py`
- Modify: `C:/Users/Samuel/Documents/Modelo Abates LoL/tests_python/test_streamlit_interface.py`

**Interfaces:**
- Consumes: the new Dota quote result contract.
- Produces: Dota UI with the same functional output as LoL for one, two, or three quotes.

- [x] **Step 1: Add failing interface assertions**

Assert that the Dota tab renders interval, EV conservador, probability/odds fields, confidence/action information, and no mismatch warning for a different soft line.

- [x] **Step 2: Update rendering**

Render the primary prediction and the per-quote confiômetro using the same labels and field semantics as the LoL synthetic block. Keep Dota-specific title and team/feature inputs.

- [x] **Step 3: Run UI tests**

Run:

```powershell
py -3 -m pytest tests_python/test_streamlit_interface.py tests_python/test_dota_synthetic_streamlit.py -q
```

Expected: all focused UI and Dota tests pass.

### Task 5: Full verification and artifact review

**Files:**
- Verify: `C:/Users/Samuel/Documents/Modelo Abates LoL/app/dota_synthetic.py`
- Verify: `C:/Users/Samuel/Documents/Modelo Abates LoL/app/dota_inference.py`
- Verify: `C:/Users/Samuel/Documents/Modelo Abates LoL/app_data/dota2_pinnacle_pre_draft_bundle.json`
- Verify: `C:/Users/Samuel/Documents/Modelo Abates LoL/tests_python/test_dota_synthetic_streamlit.py`

**Interfaces:**
- Consumes: all implementation tasks.
- Produces: fresh evidence that the Dota tab is functionally equivalent to the LoL quote flow and remains manual-only.

- [x] **Step 1: Run Python compilation**

```powershell
py -3 -m py_compile app/dota_inference.py app/dota_synthetic.py
```

- [x] **Step 2: Run focused tests**

```powershell
py -3 -m pytest tests_python/test_dota_synthetic_streamlit.py tests_python/test_streamlit_interface.py -q
```

- [x] **Step 3: Run the full Python suite**

```powershell
py -3 -m pytest tests_python -q
```

- [x] **Step 4: Check bundle security and diff hygiene**

```powershell
rg -n -i "BETTINGISCOOL_API_KEY|key\.txt|api_key" app_data/dota2_pinnacle_pre_draft_bundle.json app/dota_inference.py app/dota_synthetic.py
git diff --check
git status --short
```

Expected: no secret references, no whitespace errors, and only scoped changes are reported for this task.

- [x] **Step 5: Record the result**

Update the Dota interface/model documentation with the new quote contract, bundle provenance, and verification commands. Report any external Streamlit deployment check separately from local test evidence.
