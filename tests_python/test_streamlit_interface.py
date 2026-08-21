import json
from pathlib import Path

import pytest
from streamlit.testing.v1 import AppTest
from app.ui_options import team_label


def _fill_moneyline(app):
    next(
        item
        for item in app.text_input
        if item.label == "Casa soft"
    ).set_value("Soft Test")
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


@pytest.mark.skip(reason="Directed-model team selector retired from the public interface")
def test_streamlit_loads_and_exposes_every_team_in_default_league():
    bundle = json.loads(
        Path("app_data/model_bundle.json").read_text(encoding="utf-8")
    )
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    assert len(app.exception) == 0
    assert any(
        "Interface synthetic-pinnacle-direct-v7-2026-08-05" in markdown.value
        for markdown in app.markdown
    )
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


@pytest.mark.skip(reason="Directed-model team selector retired from the public interface")
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


@pytest.mark.skip(reason="Post-draft workflow retired from the public interface")
def test_default_draft_produces_a_prediction_without_ui_error():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    app = _fill_moneyline(app)
    app.button[0].click().run(timeout=30)

    assert len(app.exception) == 0
    metric_labels = {metric.label for metric in app.metric}
    assert {
        "Odd justa Over",
        "Odd soft Over",
        "Odd justa Under",
        "Odd soft Under",
        "EV Over",
        "EV Under",
        "Leitura Pinnacle",
        "Leitura estrutural",
    }.issubset(metric_labels)
    assert any(
            "Versão da interface: synthetic-pinnacle-direct-v7-2026-08-05"
        in caption.value
        for caption in app.caption
    )
    assert any(
        message.value.startswith("Previsão calculada. Referência ativa:")
        for message in app.success
    )
    assert any(
        message.value in {
            "Modelos concordam em uma aposta. Over confirmado.",
            "Modelos concordam em uma aposta. Under confirmado.",
            "Confiança alta de tendência. Sinal verde para Over.",
            "Confiança alta de tendência. Sinal verde para Under.",
            "Modelos divergem. Apostar 0.5u no lado da Pinnacle: Over.",
            "Modelos divergem. Apostar 0.5u no lado da Pinnacle: Under.",
            "Nenhum valor indicado. Não apostar.",
            "Pinnacle se opõe ao sinal estrutural. Não apostar.",
            "Somente o modelo estrutural indica valor; Pinnacle neutra.",
            "Pinnacle indica valor. Apostar 0.5u no lado da Pinnacle: Over.",
            "Pinnacle indica valor. Apostar 0.5u no lado da Pinnacle: Under.",
            (
                "Divergência extrema entre estrutural e Pinnacle. "
                "Não tratar como confiança alta."
            ),
        }
        for message in [*app.success, *app.warning, *app.info]
    )
    assert "Aposta confirmada" not in [
        selectbox.label for selectbox in app.selectbox
    ]
    assert {
        "Confirmar Over",
        "Confirmar Under",
        "Não apostar",
    }.issubset({button.label for button in app.button})


@pytest.mark.skip(reason="Directed fallback retired from the public interface")
def test_streamlit_uses_directed_fallback_without_pinnacle_total():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()
    next(
        item
        for item in app.checkbox
        if item.label.startswith("Total Pinnacle disponível")
    ).set_value(False).run()
    next(
        item for item in app.text_input if item.label == "Casa soft"
    ).set_value("Soft Test")
    for label, value in (
        ("Moneyline equipe A", 1.90),
        ("Moneyline equipe B", 1.90),
        ("Odd Over soft", 1.95),
        ("Odd Under soft", 1.95),
    ):
        next(
            item for item in app.number_input if item.label == label
        ).set_value(value)
    app.button[0].click().run(timeout=30)
    assert len(app.exception) == 0
    assert any(
        "Fallback ativo: Modelo dirigido + moneyline" in message.value
        for message in app.info
    )
    assert any(
        "Confiômetro indisponível" in message.value
        for message in app.info
    )


@pytest.mark.skip(reason="Directed fallback retired from the public interface")
def test_streamlit_uses_automatic_fallback_for_empty_pinnacle_odds():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()
    next(
        item for item in app.text_input if item.label == "Casa soft"
    ).set_value("Soft Test")
    for label, value in (
        ("Moneyline equipe A", 1.90),
        ("Moneyline equipe B", 1.90),
        ("Odd Over soft", 1.95),
        ("Odd Under soft", 1.95),
    ):
        next(
            item for item in app.number_input if item.label == label
        ).set_value(value)
    app.button[0].click().run(timeout=30)
    assert len(app.exception) == 0
    assert any(
        "Fallback ativo: Modelo dirigido + moneyline" in message.value
        for message in app.info
    )


@pytest.mark.skip(reason="Post-draft soft quote collection retired from the public interface")
def test_streamlit_requires_bookmaker_for_manual_soft_collection():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    app.button[0].click().run(timeout=30)

    assert any(
        "Informe a casa soft" in message.value
        for message in app.error
    )


@pytest.mark.skip(reason="Post-draft bet decisions retired from the public interface")
@pytest.mark.parametrize(
    ("button_label", "saved_message"),
    [
        ("Confirmar Over", "Decisão salva: Over, stake de"),
        ("Confirmar Under", "Decisão salva: Under, stake de"),
        ("Não apostar", "Decisão salva: não apostar."),
    ],
)
def test_all_three_decision_buttons_are_confirmed(
    button_label,
    saved_message,
):
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    app = _fill_moneyline(app)
    app.button[0].click().run(timeout=30)
    decision_button = next(
        button for button in app.button if button.label == button_label
    )
    decision_button.click().run(timeout=30)

    assert len(app.exception) == 0
    assert any(
        saved_message in message.value
        for message in app.success
    )


@pytest.mark.skip(reason="Temporal tracking retired from the public interface")
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


def test_synthetic_pinnacle_page_uses_no_moneyline_input():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    assert not app.radio

    assert len(app.exception) == 0
    assert any(
        title.value == "Pinnacle sintética pré-abertura"
        for title in app.title
    )
    assert not any(
        "Moneyline" in item.label
        for item in app.number_input
    )


def test_synthetic_hero_shows_the_latest_training_date():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    assert len(app.exception) == 0
    assert any(
        "Treinado em 20/08/2026" in markdown.value
        for markdown in app.markdown
    )


@pytest.mark.skip(reason="Post-draft soft quote collection retired from the public interface")
def test_current_model_exposes_three_optional_soft_quotes():
    app = AppTest.from_file("streamlit_app.py", default_timeout=20).run()
    for label in ("Adicionar cotação soft 2", "Adicionar cotação soft 3"):
        next(item for item in app.checkbox if item.label == label).set_value(True).run()
    labels = {item.label for item in app.number_input}
    assert {"Linha soft", "Linha soft 2", "Linha soft 3"}.issubset(labels)
    assert {"Odd Over soft 2", "Odd Under soft 3"}.issubset(labels)


def test_synthetic_model_exposes_three_optional_soft_quotes():
    app = AppTest.from_file("streamlit_app.py", default_timeout=20).run()
    assert not app.radio
    for label in (
        "Adicionar cotação sintética 2",
        "Adicionar cotação sintética 3",
    ):
        next(item for item in app.checkbox if item.label == label).set_value(True).run()
    labels = {item.label for item in app.number_input}
    assert {
        "Linha soft sintética", "Linha soft sintética 2",
        "Linha soft sintética 3",
    }.issubset(labels)


def test_synthetic_model_calculates_three_soft_quotes_without_ui_error():
    app = AppTest.from_file("streamlit_app.py", default_timeout=20).run()
    assert not app.radio
    for label in (
        "Adicionar cotação sintética 2",
        "Adicionar cotação sintética 3",
    ):
        next(item for item in app.checkbox if item.label == label).set_value(True).run()
    for label, value in (
        ("Casa soft sintética", "Soft 1"),
        ("Casa soft sintética 2", "Soft 2"),
        ("Casa soft sintética 3", "Soft 3"),
    ):
        next(item for item in app.text_input if item.label == label).set_value(value)
    next(
        button for button in app.button
        if button.label == "Calcular Pinnacle sintética"
    ).click().run(timeout=30)
    assert len(app.exception) == 0
    assert any(
        metric.label == "Linha Pinnacle final esperada" for metric in app.metric
    )
    assert sum(
        "Confiômetro:" in info.value for info in app.info
    ) >= 3


@pytest.mark.skip(reason="Post-draft soft quote collection retired from the public interface")
def test_current_model_calculates_three_soft_quotes_without_ui_error():
    app = AppTest.from_file("streamlit_app.py", default_timeout=20).run()
    for label in ("Adicionar cotação soft 2", "Adicionar cotação soft 3"):
        next(item for item in app.checkbox if item.label == label).set_value(True).run()
    for label, value in (("Casa soft 2", "Soft 2"), ("Casa soft 3", "Soft 3")):
        next(item for item in app.text_input if item.label == label).set_value(value)
    app = _fill_moneyline(app)
    next(
        button for button in app.button if button.label == "Calcular previsão"
    ).click().run(timeout=30)
    assert len(app.exception) == 0
    assert any(
        "Confiômetro e valor por cotação soft" in subheader.value
        for subheader in app.subheader
    )


@pytest.mark.skip(reason="Bet history retired from the public interface")
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


@pytest.mark.skip(reason="Directed-model team selector retired from the public interface")
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


def test_streamlit_opens_directly_in_synthetic_pinnacle_without_navigation():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    assert len(app.exception) == 0
    assert any(
        title.value == "Pinnacle sintética pré-abertura"
        for title in app.title
    )
    assert not app.radio


def test_synthetic_page_has_no_retired_postdraft_labels():
    app = AppTest.from_file(
        "streamlit_app.py",
        default_timeout=20,
    ).run()

    labels = {
        item.label
        for item in [
            *app.button,
            *app.checkbox,
            *app.number_input,
            *app.selectbox,
            *app.text_input,
        ]
    }
    assert "Total Pinnacle disponível no snapshot pós-draft/live open" not in labels
    assert "Moneyline equipe A" not in labels
    assert "Confirmar Over" not in labels
