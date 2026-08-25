# Dota 2 Team-First Selector Implementation Plan

> For agentic workers: use executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

Goal: Retirar a competição como filtro obrigatório dos times Dota, mantendo-a como contexto opcional da resolução point-in-time.

Architecture: O catálogo da UI será transformado em um índice global deduplicado por team_id a partir das competições S/A. A aba exibirá Automática e as competições como contexto; os dois times serão escolhidos do índice global. O resolvedor manterá a prioridade contextual e o fallback global.

Tech Stack: Python, Streamlit, streamlit.testing.v1.AppTest, pytest.

## Global Constraints

- Não alterar o bundle, as oito features ou o contrato pré-draft.
- Não usar a liga como feature operacional.
- Não inventar IDs, sides ou histórico.
- Manter o fallback point-in-time e a comparação manual.
- Não alterar o fluxo do LoL.

---

### Task 1: Regression tests for team-first behavior

Files:
- Modify: tests_python/test_dota_synthetic_streamlit.py
- Modify: tests_python/test_streamlit_pinnacle_tabs.py

Interfaces:
- Consumes: current catalog and Dota Streamlit tab.
- Produces: tests for global ID deduplication, optional competition, and global team options.

- [ ] Step 1: Write the failing tests

Test a small catalog with the same team ID in two competitions and assert one global entry with two competitions. Test that the rendered Dota team selector contains more entries than the first competition and that the competition selector starts with Automática.

- [ ] Step 2: Run the focused tests

~~~powershell
py -3 -m pytest tests_python/test_dota_synthetic_streamlit.py tests_python/test_streamlit_pinnacle_tabs.py -q
~~~

Expected: the new assertions fail because the current UI restricts teams to the selected competition.

### Task 2: Implement global catalog and optional competition

Files:
- Modify: app/dota_synthetic.py

Interfaces:
- Consumes: catalog leagues with source_league_id, league_name, tier, and teams.
- Produces: build_dota_team_catalog(catalog) and a team-first render_dota_tab flow.

- [ ] Step 1: Implement build_dota_team_catalog

Aggregate all catalog league teams by string team_id, keep the latest display name by last_seen, retain sorted competition metadata, and return deterministic team IDs and labels.

- [ ] Step 2: Add the Automática competition option

Use a sentinel context ID and keep all real competition options available. Use global history for Automática and selected competition history followed by global fallback for a real selection.

- [ ] Step 3: Change both team selectors to the global catalog

Build team options once from all eligible S/A competitions, exclude the selected team from the second selector, and preserve stable Streamlit keys.

- [ ] Step 4: Update metadata and captions

Record the optional competition context and use source_scope values that distinguish global history from selected competition plus global fallback.

### Task 3: Verification and publication

Files:
- Inspect: app/dota_synthetic.py
- Inspect: tests_python/test_dota_synthetic_streamlit.py
- Inspect: tests_python/test_streamlit_pinnacle_tabs.py

Interfaces:
- Consumes: completed team-first Dota tab.
- Produces: tested and published repository state.

- [ ] Step 1: Run focused and full tests

~~~powershell
py -3 -m pytest tests_python/test_dota_synthetic_streamlit.py tests_python/test_streamlit_pinnacle_tabs.py -q
py -3 -m pytest tests_python -q
~~~

- [ ] Step 2: Compile and check the diff

~~~powershell
py -3 -m py_compile app/dota_synthetic.py tests_python/test_dota_synthetic_streamlit.py tests_python/test_streamlit_pinnacle_tabs.py
git diff --check
~~~

- [ ] Step 3: Validate the rendered UI

Open the Streamlit app, select the Dota tab, confirm Automática is present, confirm both team selectors expose the global catalog, and run a prediction using the automatic context.

- [ ] Step 4: Commit and push only the feature files

~~~powershell
git add app/dota_synthetic.py tests_python/test_dota_synthetic_streamlit.py tests_python/test_streamlit_pinnacle_tabs.py docs/superpowers/specs/2026-08-25-dota-team-first-selector-design.md docs/superpowers/plans/2026-08-25-dota-team-first-selector.md
git commit -m "feat: make Dota team selection competition agnostic"
git push origin main
~~~
