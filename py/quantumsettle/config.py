from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

PROJECT_ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=PROJECT_ROOT / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    db_dsn: str = Field(default="localhost:1521/FREEPDB1", alias="QS_DB_DSN")
    db_user: str = Field(default="qsettle", alias="QS_DB_USER")
    db_password: str = Field(default="", alias="QS_DB_PASSWORD")
    db_admin_user: str = Field(default="SYSTEM", alias="QS_DB_ADMIN_USER")
    db_admin_password: str = Field(default="", alias="QS_DB_ADMIN_PASSWORD")


settings = Settings()
