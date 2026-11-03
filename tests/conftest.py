"""Shared fixtures: S3 and SSM in memory (moto), ENTSO-E mocked (respx).

No test reaches AWS or ENTSO-E. Fake credentials are set for every test, so
a developer's real `energy` profile can't be used by accident either.
"""

from __future__ import annotations

import os
from collections.abc import Iterator
from pathlib import Path
from typing import TYPE_CHECKING, Final

import boto3
import pytest
from moto import mock_aws

from energy import secrets
from energy.config import Settings

if TYPE_CHECKING:
    from types_boto3_s3 import S3Client
    from types_boto3_ssm import SSMClient

FIXTURES = Path(__file__).parent / "fixtures"
BUCKET = "energy-lake-test"
REGION: Final = "eu-central-1"
TOKEN = "test-token-0123456789"
TOKEN_PARAMETER = "/energy/entsoe/token"
SOURCE = "https://source.test/api"


@pytest.fixture(autouse=True)
def _isolate_env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    for key in [k for k in os.environ if k.startswith(("ENERGY_", "AWS_"))]:
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    monkeypatch.setattr("time.sleep", lambda _seconds: None)  # no real retry backoff
    secrets.forget()
    yield
    secrets.forget()


@pytest.fixture
def settings() -> Settings:
    return Settings(lake_bucket=BUCKET, source_base_url=SOURCE)


@pytest.fixture
def aws() -> Iterator[None]:
    """An empty account: the lake bucket and the token parameter."""
    with mock_aws():
        boto3.client("s3").create_bucket(
            Bucket=BUCKET, CreateBucketConfiguration={"LocationConstraint": REGION}
        )
        boto3.client("ssm").put_parameter(Name=TOKEN_PARAMETER, Value=TOKEN, Type="SecureString")
        yield


@pytest.fixture
def s3(aws: None) -> S3Client:
    return boto3.client("s3")


@pytest.fixture
def ssm(aws: None) -> SSMClient:
    return boto3.client("ssm")
