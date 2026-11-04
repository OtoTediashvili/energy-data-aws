"""Extract: the failure modes matter more than a 200.

Retryable versus permanent errors, the token staying out of every log and
traceback, and reruns that overwrite instead of duplicating. Most of these
come from project 1, now against S3 (moto) instead of a folder.
"""

from __future__ import annotations

import logging
from datetime import date
from typing import TYPE_CHECKING

import httpx
import pytest
import respx
from pydantic import SecretStr
from structlog.testing import capture_logs

from energy.config import Settings
from energy.extract import (
    TOKEN_PARAM,
    NoMatchingDataError,
    PermanentSourceError,
    TransientSourceError,
    extract,
    fetch,
)
from energy.layout import landing_key
from tests.conftest import BUCKET, FIXTURES, SOURCE

if TYPE_CHECKING:
    from mypy_boto3_s3 import S3Client

DAY = date(2026, 9, 24)
NL = "10YNL----------L"
TOKEN = SecretStr("test-key")
PARAMS = {"documentType": "A44"}
DOCUMENT = (FIXTURES / "entsoe_a44_nl_20260924.xml").read_bytes()

ACK = (
    b'<?xml version="1.0" encoding="UTF-8"?>\n'
    b"<Acknowledgement_MarketDocument"
    b' xmlns="urn:iec62325.351:tc57wg16:451-1:acknowledgementdocument:7:0">'
    b"<Reason><code>999</code><text>No matching data found</text></Reason>"
    b"</Acknowledgement_MarketDocument>"
)


def landed(s3: S3Client) -> list[str]:
    listing = s3.list_objects_v2(Bucket=BUCKET, Prefix="landing/")
    return [item["Key"] for item in listing.get("Contents", [])]


# ------------------------------------------------------------------- fetch


@respx.mock
def test_fetch_sends_the_token_as_a_query_parameter(settings: Settings) -> None:
    """ENTSO-E reads securityToken from the query string and ignores headers."""
    route = respx.get(SOURCE).mock(return_value=httpx.Response(200, content=b"<ok/>"))
    assert fetch(PARAMS, TOKEN, settings) == b"<ok/>"
    request = route.calls.last.request
    assert request.url.params[TOKEN_PARAM] == "test-key"
    assert request.url.params["documentType"] == "A44"
    assert "Authorization" not in request.headers


@respx.mock
def test_fetch_never_logs_the_token(settings: Settings) -> None:
    respx.get(SOURCE).mock(return_value=httpx.Response(200, content=b"<ok/>"))
    with capture_logs() as events:
        fetch(PARAMS, TOKEN, settings)
    assert events, "fetch should log its request"
    assert all("test-key" not in repr(event) for event in events)


@respx.mock
def test_no_library_log_line_carries_the_token(
    settings: Settings, caplog: pytest.LogCaptureFixture
) -> None:
    """httpx logs the full URL, token included, at INFO. In Lambda that goes
    to CloudWatch. Capture every logger at every level."""
    respx.get(SOURCE).mock(return_value=httpx.Response(200, content=b"<ok/>"))
    with caplog.at_level(logging.DEBUG):
        fetch(PARAMS, TOKEN, settings)
    assert "test-key" not in caplog.text


@respx.mock
def test_a_failed_request_cannot_leak_the_token_through_a_traceback(settings: Settings) -> None:
    """Lambda prints an unhandled exception's traceback to CloudWatch. Run
    the real retry path to its final re-raise, then walk every frame a
    renderer could reach, chained exceptions included, and check every local."""
    route = respx.get(SOURCE).mock(side_effect=httpx.ConnectError("Connection refused"))
    with pytest.raises(TransientSourceError) as caught:
        fetch(PARAMS, TOKEN, settings)
    assert route.call_count == 4, "a transport failure must still be retried"
    assert "Connection refused" in str(caught.value), "the cause must stay diagnosable"

    exc: BaseException | None = caught.value
    while exc is not None:
        frame = exc.__traceback__
        while frame is not None:
            for name, value in frame.tb_frame.f_locals.items():
                if isinstance(value, SecretStr):
                    continue  # prints as '**********'
                assert "test-key" not in repr(value), f"token in local '{name}'"
            frame = frame.tb_next
        exc = exc.__cause__ or exc.__context__


@respx.mock
def test_fetch_retries_a_503_then_succeeds(settings: Settings) -> None:
    respx.get(SOURCE).mock(
        side_effect=[httpx.Response(503), httpx.Response(503), httpx.Response(200, content=b"ok")]
    )
    assert fetch(PARAMS, TOKEN, settings) == b"ok"


@respx.mock
def test_fetch_gives_up_after_four_tries(settings: Settings) -> None:
    route = respx.get(SOURCE).mock(return_value=httpx.Response(429))
    with pytest.raises(TransientSourceError, match="429"):
        fetch(PARAMS, TOKEN, settings)
    assert route.call_count == 4


@respx.mock
def test_a_4xx_fails_fast(settings: Settings) -> None:
    route = respx.get(SOURCE).mock(return_value=httpx.Response(401, text="bad token"))
    with pytest.raises(PermanentSourceError, match="401"):
        fetch(PARAMS, TOKEN, settings)
    assert route.call_count == 1, "a 4xx must fail fast, not burn the retries"


# ----------------------------------------------------------------- landing


@respx.mock
def test_extract_lands_the_bytes_unmodified(s3: S3Client, settings: Settings) -> None:
    respx.get(SOURCE).mock(return_value=httpx.Response(200, content=DOCUMENT))
    key, size = extract("NL", NL, DAY, token=TOKEN, s3=s3, settings=settings)
    assert key == landing_key("NL", DAY)
    assert size == len(DOCUMENT)
    assert s3.get_object(Bucket=BUCKET, Key=key)["Body"].read() == DOCUMENT


@respx.mock
def test_extract_asks_for_the_runs_utc_day(s3: S3Client, settings: Settings) -> None:
    route = respx.get(SOURCE).mock(return_value=httpx.Response(200, content=DOCUMENT))
    extract("NL", NL, DAY, token=TOKEN, s3=s3, settings=settings)
    params = route.calls.last.request.url.params
    assert (params["periodStart"], params["periodEnd"]) == ("202609240000", "202609250000")
    assert params["in_Domain"] == params["out_Domain"] == NL


@respx.mock
def test_running_a_day_again_overwrites_its_one_file(s3: S3Client, settings: Settings) -> None:
    """The idempotency a backfill relies on."""
    respx.get(SOURCE).mock(
        side_effect=[
            httpx.Response(200, content=b"<Publication_MarketDocument>first"),
            httpx.Response(200, content=b"<Publication_MarketDocument>second"),
        ]
    )
    extract("NL", NL, DAY, token=TOKEN, s3=s3, settings=settings)
    extract("NL", NL, DAY, token=TOKEN, s3=s3, settings=settings)
    assert landed(s3) == [landing_key("NL", DAY)]
    body = s3.get_object(Bucket=BUCKET, Key=landing_key("NL", DAY))["Body"].read()
    assert body.endswith(b"second")


@respx.mock
def test_an_acknowledgement_with_http_200_is_not_landed(s3: S3Client, settings: Settings) -> None:
    """ENTSO-E can answer 'no data' with a 200, so fetch() itself succeeds."""
    respx.get(SOURCE).mock(return_value=httpx.Response(200, content=ACK))
    with pytest.raises(PermanentSourceError, match="999: No matching data found"):
        extract("NL", NL, DAY, token=TOKEN, s3=s3, settings=settings)
    assert landed(s3) == []


@respx.mock
def test_no_matching_data_has_its_own_error_for_the_state_machine_to_wait_on(
    s3: S3Client, settings: Settings
) -> None:
    """Reason 999 is what tomorrow's prices look like before they're published.
    The state machine retries that error by name, minutes apart."""
    respx.get(SOURCE).mock(return_value=httpx.Response(200, content=ACK))
    with pytest.raises(NoMatchingDataError):
        extract("NL", NL, DAY, token=TOKEN, s3=s3, settings=settings)


@respx.mock
def test_any_other_acknowledgement_is_not_worth_waiting_for(
    s3: S3Client, settings: Settings
) -> None:
    other = ACK.replace(b"<code>999</code>", b"<code>B11</code>").replace(
        b"No matching data found", b"Unknown bidding zone"
    )
    respx.get(SOURCE).mock(return_value=httpx.Response(200, content=other))
    with pytest.raises(PermanentSourceError, match="B11: Unknown bidding zone") as caught:
        extract("NL", NL, DAY, token=TOKEN, s3=s3, settings=settings)
    assert not isinstance(caught.value, NoMatchingDataError)


@respx.mock
def test_an_acknowledgement_cannot_overwrite_a_good_day(s3: S3Client, settings: Settings) -> None:
    """A rerun on a bad day must never destroy the one raw copy of a good one."""
    respx.get(SOURCE).mock(
        side_effect=[httpx.Response(200, content=DOCUMENT), httpx.Response(200, content=ACK)]
    )
    key, _ = extract("NL", NL, DAY, token=TOKEN, s3=s3, settings=settings)
    with pytest.raises(PermanentSourceError):
        extract("NL", NL, DAY, token=TOKEN, s3=s3, settings=settings)
    assert s3.get_object(Bucket=BUCKET, Key=key)["Body"].read() == DOCUMENT


@respx.mock
def test_the_reason_is_found_beyond_the_first_400_bytes(s3: S3Client, settings: Settings) -> None:
    """ENTSO-E's reason sits after the sender and receiver headers."""
    padded = ACK.replace(
        b"<Reason>",
        b"<sender_MarketParticipant.mRID codingScheme='A01'>10X1001A1001A450"
        b"</sender_MarketParticipant.mRID>" * 6 + b"<Reason>",
    )
    assert padded.index(b"<Reason>") > 400
    respx.get(SOURCE).mock(return_value=httpx.Response(200, content=padded))
    with pytest.raises(PermanentSourceError, match="999: No matching data found"):
        extract("NL", NL, DAY, token=TOKEN, s3=s3, settings=settings)


def test_extract_without_a_bucket_says_so(s3: S3Client) -> None:
    with pytest.raises(RuntimeError, match="ENERGY_LAKE_BUCKET"):
        Settings().bucket()
