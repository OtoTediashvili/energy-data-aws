"""Settings, from environment variables prefixed ENERGY_.

In Lambda, Terraform sets them on each function. Nothing else in the code
reads os.environ. The ENTSO-E token is not a setting: it is read from SSM
Parameter Store at run time (see secrets.py), so it never sits in an
environment variable, a Terraform state file or the function's
configuration.
"""

from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="ENERGY_", extra="ignore")

    lake_bucket: str = Field(default="", description="The data lake bucket")
    token_parameter: str = Field(
        default="/energy/entsoe/token",
        description="SSM parameter (SecureString) holding the ENTSO-E token",
    )
    source_base_url: str = "https://web-api.tp.entsoe.eu/api"
    request_timeout_seconds: float = Field(default=30.0, gt=0)
    log_level: str = "INFO"
    log_json: bool = Field(default=False, description="JSON logs; on in Lambda")

    def bucket(self) -> str:
        """The lake bucket, or a clear error if the function wasn't given one."""
        if not self.lake_bucket:
            raise RuntimeError("ENERGY_LAKE_BUCKET is not set")
        return self.lake_bucket
