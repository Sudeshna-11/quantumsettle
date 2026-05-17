"""Smoke tests that run without a database — confirms Python package wires up."""

from quantumsettle import __version__
from quantumsettle.config import settings


def test_version_string() -> None:
    assert __version__


def test_settings_load() -> None:
    # Smoke: pydantic-settings should construct even if .env is missing.
    assert settings.db_dsn
    assert settings.db_user
