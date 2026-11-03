"""Lambda entry points. One container image, one function per handler.

Each takes and returns the same small document, so the state machine can
pass extract's output straight to parse:

    {"zone": "NL", "eic": "10YNL----------L", "logical_date": "2026-11-01"}

extract adds "landing_key" and "bytes"; parse adds "parsed_key" and "rows".
Without logical_date, both use today's date in UTC.
"""

from __future__ import annotations

from datetime import UTC, date, datetime
from typing import Any

import boto3
from pydantic import BaseModel, Field, field_validator

from energy import extract as extract_step
from energy import parse as parse_step
from energy.config import Settings
from energy.layout import validate_eic, validate_zone_key
from energy.logging_config import configure_logging, get_logger
from energy.secrets import entsoe_token

log = get_logger(__name__)


def _today() -> date:
    return datetime.now(UTC).date()


class Delivery(BaseModel):
    """One zone's request for one day."""

    zone: str
    eic: str
    logical_date: date = Field(default_factory=_today)

    @field_validator("zone")
    @classmethod
    def _zone(cls, value: str) -> str:
        return validate_zone_key(value)

    @field_validator("eic")
    @classmethod
    def _eic(cls, value: str) -> str:
        return validate_eic(value)

    def describe(self) -> dict[str, Any]:
        return {"zone": self.zone, "eic": self.eic, "logical_date": self.logical_date.isoformat()}


def _setup() -> Settings:
    settings = Settings()
    configure_logging(settings.log_level, settings.log_json)
    return settings


def extract(event: dict[str, Any], context: object = None) -> dict[str, Any]:
    """ENTSO-E -> landing/. Fails on an Acknowledgement (no data yet, or an error)."""
    settings = _setup()
    delivery = Delivery.model_validate(event)
    log.info("extract.start", **delivery.describe())
    token = entsoe_token(boto3.client("ssm"), settings.token_parameter)
    key, size = extract_step.extract(
        delivery.zone,
        delivery.eic,
        delivery.logical_date,
        token=token,
        s3=boto3.client("s3"),
        settings=settings,
    )
    return {**delivery.describe(), "landing_key": key, "bytes": size}


def parse(event: dict[str, Any], context: object = None) -> dict[str, Any]:
    """landing/ -> parsed/. Reads only what extract landed for the same zone and day."""
    settings = _setup()
    delivery = Delivery.model_validate(event)
    log.info("parse.start", **delivery.describe())
    key, rows = parse_step.parse_delivery(
        delivery.zone,
        delivery.eic,
        delivery.logical_date,
        s3=boto3.client("s3"),
        bucket=settings.bucket(),
        now=datetime.now(UTC),
    )
    return {**delivery.describe(), "parsed_key": key, "rows": rows}
