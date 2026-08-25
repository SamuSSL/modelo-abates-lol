from __future__ import annotations

from streamlit.testing.v1 import AppTest


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
