from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    db_host: str
    db_port: int = 5432
    db_name: str
    db_user: str
    db_password: str

    # Cache (ADR-0011). "disabled" = la app funciona solo contra PostgreSQL.
    cache_host: str = "disabled"
    cache_port: int = 6379
    cache_tls: bool = True
    cache_ttl_seconds: int = 300

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+psycopg2://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )


settings = Settings()