"""The Lambda handlers, end to end on moto: token from SSM, ENTSO-E mocked,
the landed XML and the parsed Parquet in S3."""

from __future__ import annotations

import io
from datetime import UTC, datetime
from typing import TYPE_CHECKING

import httpx
import pyarrow.parquet as pq
import pytest
import respx
from pydantic import ValidationError

from energy import handlers
from energy.secrets import entsoe_token
from tests.conftest import BUCKET, FIXTURES, SOURCE, TOKEN, TOKEN_PARAMETER

if TYPE_CHECKING:
    from types_boto3_s3 import S3Client
    from types_boto3_ssm import SSMClient

EVENT = {"zone": "NL", "eic": "10YNL----------L", "logical_date": "2026-09-24"}
DOCUMENT = (FIXTURES / "entsoe_a44_nl_20260924.xml").read_bytes()


@pytest.fixture
def function_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """What Terraform sets on the functions."""
    monkeypatch.setenv("ENERGY_LAKE_BUCKET", BUCKET)
    monkeypatch.setenv("ENERGY_SOURCE_BASE_URL", SOURCE)
    monkeypatch.setenv("ENERGY_TOKEN_PARAMETER", TOKEN_PARAMETER)
    monkeypatch.setenv("ENERGY_LOG_JSON", "true")


@respx.mock
def test_extract_then_parse(s3: S3Client, function_env: None) -> None:
    route = respx.get(SOURCE).mock(return_value=httpx.Response(200, content=DOCUMENT))

    extracted = handlers.extract(EVENT)
    assert extracted == {
        **EVENT,
        "landing_key": "landing/dataset=prices/zone=NL/year=2026/month=09/prices_NL_2026-09-24.xml",
        "bytes": len(DOCUMENT),
    }
    assert route.calls.last.request.url.params["securityToken"] == TOKEN

    # The state machine hands extract's output straight to parse.
    parsed = handlers.parse(extracted)
    assert parsed == {
        **EVENT,
        "parsed_key": (
            "parsed/dataset=prices/zone=NL/year=2026/month=09/prices_NL_2026-09-24.parquet"
        ),
        "rows": 192,
    }
    body = s3.get_object(Bucket=BUCKET, Key=parsed["parsed_key"])["Body"].read()
    assert pq.read_table(io.BytesIO(body)).num_rows == 192


@respx.mock
def test_without_a_date_the_run_is_for_today_in_utc(s3: S3Client, function_env: None) -> None:
    route = respx.get(SOURCE).mock(return_value=httpx.Response(200, content=DOCUMENT))
    result = handlers.extract({"zone": "NL", "eic": "10YNL----------L"})
    today = datetime.now(UTC).date()
    assert result["logical_date"] == today.isoformat()
    assert route.calls.last.request.url.params["periodStart"] == f"{today:%Y%m%d}0000"


@pytest.mark.parametrize(
    "event",
    [
        {"zone": "../x", "eic": "10YNL----------L"},
        {"zone": "NL", "eic": "not-an-eic"},
        {"zone": "NL", "eic": "10YNL----------L", "logical_date": "24/09/2026"},
        {"eic": "10YNL----------L"},
    ],
)
def test_a_malformed_event_is_refused_before_anything_runs(
    s3: S3Client, function_env: None, event: dict[str, str]
) -> None:
    with pytest.raises(ValidationError):
        handlers.extract(event)
    assert s3.list_objects_v2(Bucket=BUCKET).get("KeyCount") == 0


def test_the_token_is_read_once_per_warm_container(ssm: SSMClient) -> None:
    """Four zones a day, one SSM call: the cache outlives the parameter."""
    first = entsoe_token(ssm, TOKEN_PARAMETER)
    ssm.delete_parameter(Name=TOKEN_PARAMETER)
    assert entsoe_token(ssm, TOKEN_PARAMETER) is first
    assert first.get_secret_value() == TOKEN
    assert "test-token" not in repr(first)
