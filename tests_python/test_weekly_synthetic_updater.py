from pathlib import Path


def test_weekly_synthetic_updater_exists():
    assert Path("scripts/atualizar_pinnacle_sintetica.ps1").exists()
