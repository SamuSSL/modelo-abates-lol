from pathlib import Path


def test_weekly_synthetic_updater_exists():
    assert Path("scripts/atualizar_pinnacle_sintetica.ps1").exists()


def test_weekly_synthetic_updater_uses_git_exit_codes_for_publication():
    source = Path("scripts/atualizar_pinnacle_sintetica.ps1").read_text(
        encoding="utf-8-sig"
    )

    assert "function Invoke-Git" in source
    assert "Invoke-Git @('push', 'origin', 'HEAD:main')" in source
    assert "Invoke-Git @('ls-remote', 'origin', 'refs/heads/main')" in source
