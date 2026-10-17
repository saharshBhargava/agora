from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

DEFAULT_DEV_SECRET = "dev-only-secret-change-me-0123456789abcdef"  # noqa: S105 - local-only default, refused in demo


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="AGORA_", extra="ignore")

    # dev/test: local. demo: hosted hackathon deploy with dev auth limited to seeded users. prod: real IdP only.
    env: Literal["dev", "test", "demo", "prod"] = "dev"
    database_url: SecretStr = SecretStr("postgresql://agora:agora-dev-only@127.0.0.1:5433/agora")
    db_pool_min: int = 1
    db_pool_max: int = 10

    # Auth: "dev" mints short-lived HMAC tokens for seeded demo users; "oidc" verifies an IdP's JWTs via JWKS.
    auth_mode: Literal["dev", "oidc"] = "dev"
    dev_jwt_secret: SecretStr = SecretStr(DEFAULT_DEV_SECRET)
    # In demo mode, dev login only works for these seeded handles.
    demo_handles: list[str] = Field(default_factory=lambda: ["kedar", "saharsh"])
    dev_token_ttl_s: int = 12 * 3600
    oidc_issuer: str | None = None
    oidc_audience: str | None = None
    oidc_jwks_url: str | None = None

    # Media storage: "local" writes under storage_dir; "s3" targets any S3-compatible bucket (Cloudflare R2).
    storage_backend: Literal["local", "s3"] = "local"
    storage_dir: Path = Path(".data/media")
    s3_bucket: str | None = None
    s3_endpoint_url: str | None = None
    s3_access_key_id: SecretStr | None = None
    s3_secret_access_key: SecretStr | None = None

    # Vision: primary provider plus optional fallback. "replay" serves cached/fixture results only.
    vision_provider: Literal["perceptron", "gemini", "replay"] = "replay"
    vision_fallback: Literal["perceptron", "gemini", "replay", "none"] = "none"
    perceptron_api_key: SecretStr | None = None
    perceptron_base_url: str = "https://api.perceptron.inc/v1"
    perceptron_model: str = "perceptron-mk1.5"
    gemini_api_key: SecretStr | None = None
    gemini_model: str = "gemini-flash-latest"
    vision_timeout_s: float = 45.0
    replay_dir: Path = Path(__file__).resolve().parent.parent / "seed" / "replay"

    # Upload limits.
    max_frames: int = 12
    max_image_bytes: int = 10 * 1024 * 1024
    max_video_bytes: int = 80 * 1024 * 1024
    max_image_side: int = 1600

    # Run the job worker inside the web process (single-machine deploys and local dev).
    run_worker_in_process: bool = True
    worker_concurrency: int = 2

    auto_accept_confidence: float = 0.85
    auto_accept_match: float = 0.8

    cors_origins: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def _guard_prod(self) -> "Settings":
        if self.env == "prod":
            if self.auth_mode == "dev":
                raise ValueError("AGORA_AUTH_MODE=dev is not allowed when AGORA_ENV=prod")
            if not (self.oidc_issuer and self.oidc_audience and self.oidc_jwks_url):
                raise ValueError("OIDC issuer, audience and JWKS URL are required in prod")
        if self.auth_mode == "dev":
            secret = self.dev_jwt_secret.get_secret_value()
            if len(secret) < 32:
                raise ValueError("AGORA_DEV_JWT_SECRET must be at least 32 characters")
            if self.env == "demo" and secret == DEFAULT_DEV_SECRET:
                raise ValueError("Set a unique AGORA_DEV_JWT_SECRET for demo deploys")
        if self.storage_backend == "s3" and not self.s3_bucket:
            raise ValueError("AGORA_S3_BUCKET is required when AGORA_STORAGE_BACKEND=s3")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
