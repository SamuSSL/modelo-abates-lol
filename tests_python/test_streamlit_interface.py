import json
from pathlib import Path

from streamlit.testing.v1 import AppTest
from app.ui_options import team_label


def _fill_moneyline(app):
    next(
        item
        for item in app.number_input
        if item.label == "Moneyline equipe A"
    ).set_value(1.90)
    next(
        item
        for item in app.number_input
        if item.label == "Moneyline equipe B"
    ).set_value(1.90)
    next(
        item
        for item in app.number_input
        if item.label == "Odd Over Pinnacle"
    ).set_value(1.90)
    next(
        item
        for item in app.number_input
        if item.label == "Odd Under Pinnacle"
    ).set_value(1.90)
    next(
        item
        for item in app.number_input
        if item.label == "Odd Over soft"
    ).set_value(1.95)
    next(
        item
        for item in app.number_input
        if item.label == "Odd Under soft"
    ).set_value(1.95)
    return app.run()


def test_streamlit_loads_and_exposes_every_team_in_default_league():
    bundle = json.loads(
        Path("app_data/model_bundle.json").read_text(encoding="utf-8")
    )
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    assert len(app.exception) == 0
    default_league = app.selectbox[0].value
    limit = float(bundle["sample_limits"]["team_effective_games"])
    expected = {
        team_label(row, limit)
        for row in bundle["teams"]
        if row.get("league_canonical") == default_league
        and str(row.get("last_game_datetime", "")).startswith("2026-")
    }
    assert set(app.selectbox[1].options) == expected
    assert len(expected) > 2
    assert not any(
        selectbox.label.startswith("Jogador")
        for selectbox in app.selectbox
    )
    assert not any(
        selectbox.label.startswith("Campeão")
        for selectbox in app.selectbox
    )


def test_low_sample_team_remains_selectable_with_warning():
    bundle = json.loads(
        Path("app_data/model_bundle.json").read_text(encoding="utf-8")
    )
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()
    limit = float(bundle["sample_limits"]["team_effective_games"])
    low_sample = next(
        row
        for row in bundle["teams"]
        if str(row.get("last_game_datetime", "")).startswith("2026-")
        and float(row["effective_team_games"]) < limit
    )

    app.selectbox[0].set_value(low_sample["league_canonical"]).run()
    app.selectbox[1].set_value(low_sample["key"]).run()

    assert len(app.exception) == 0
    assert app.selectbox[1].value == low_sample["key"]
    assert any(
        "abaixo do limite mínimo" in warning.value
        for warning in app.warning
    )


def test_default_draft_produces_a_prediction_without_ui_error():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    app = _fill_moneyline(app)
    app.button[0].click().run(timeout=30)

    assert len(app.exception) == 0
    assert [message.value for message in app.success] == [
        "Previsão calculada."
    ]
    assert "Aposta confirmada" not in [
        selectbox.label for selectbox in app.selectbox
    ]
    assert {
        "Confirmar Over",
        "Confirmar Under",
        "Não apostar",
    }.issubset({button.label for button in app.button})


def test_no_bet_is_confirmed_after_prediction():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    app = _fill_moneyline(app)
    app.button[0].click().run(timeout=30)
    no_bet_button = next(
        button for button in app.button if button.label == "Não apostar"
    )
    no_bet_button.click().run(timeout=30)

    assert len(app.exception) == 0
    assert any(
        "Decisão salva: não apostar." in message.value
        for message in app.success
    )


def test_tracking_page_loads_without_ui_error():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    app.radio[0].set_value("Tracking temporal").run(timeout=30)

    assert len(app.exception) == 0
    assert any(
        title.value == "Tracking temporal"
        for title in app.title
    )


def test_bet_history_page_loads_without_ui_error():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    app.radio[0].set_value("Apostas registradas").run(timeout=30)

    assert len(app.exception) == 0
    assert any(
        title.value == "Apostas registradas"
        for title in app.title
    )
    assert any(
        "Vault Corp" in markdown.value
        for markdown in app.markdown
    )


def test_changing_league_refreshes_team_options_immediately():
    bundle = json.loads(
        Path("app_data/model_bundle.json").read_text(encoding="utf-8")
    )
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()
    target_league = "LCK"
    limit = float(bundle["sample_limits"]["team_effective_games"])

    app.selectbox[0].set_value(target_league).run()

    expected = {
        team_label(row, limit)
        for row in bundle["teams"]
        if row.get("league_canonical") == target_league
        and str(row.get("last_game_datetime", "")).startswith("2026-")
    }
    assert app.selectbox[0].value == target_league
    assert set(app.selectbox[1].options) == expected
    assert len(expected) >= 2
