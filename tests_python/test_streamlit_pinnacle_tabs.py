from __future__ import annotations

from streamlit.testing.v1 import AppTest

from app.dota_synthetic import build_dota_team_catalog, load_dota_state


def test_streamlit_exposes_lol_and_dota_synthetic_pinnacle_tabs() -> None:
    app = AppTest.from_file("streamlit_app.py", default_timeout=30).run()

    assert len(app.exception) == 0
    assert [tab.label for tab in app.tabs] == [
        "LoL · Pinnacle Sintética",
        "Dota 2 · Pinnacle Sintética",
    ]
    assert [header.value for tab in app.tabs for header in tab.header] == [
        "LoL · Pinnacle Sintética",
        "Dota 2 · Pinnacle Sintética",
    ]


def test_dota_hud_uses_selectors_and_hides_manual_feature_inputs() -> None:
    app = AppTest.from_file("streamlit_app.py", default_timeout=30).run()
    dota = app.tabs[1]
    labels = [item.label for item in dota.selectbox]
    labels.extend(item.label for item in dota.number_input)
    labels.extend(item.label for item in dota.text_input)
    labels.extend(item.label for item in dota.checkbox)
    assert "Liga sintética Dota 2" in labels
    assert "Equipe 1" in labels
    assert "Equipe 2" in labels
    assert "Adicionar cotação sintética 2" in labels
    assert "Adicionar cotação sintética 3" in labels
    assert not any("kills" in label.casefold() or "meia-vida" in label.casefold() for label in labels)

    state = load_dota_state()
    assert dota.selectbox[0].options[0] == "Automática · histórico global"
    assert len(dota.selectbox[1].options) == len(build_dota_team_catalog(state["catalog"]))
