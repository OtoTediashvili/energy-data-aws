"""Extract: ask ENTSO-E for one zone's day, land the bytes in S3 unmodified.

Two rules, kept from project 1, that make reruns and backfills safe:

1. The landing key is a pure function of zone and day. Running a day again
   overwrites its one file instead of adding a duplicate.
2. Nothing is parsed or reshaped here. Whatever ENTSO-E returned is what
   lands, so a parser bug is fixed by parsing again, never by downloading
   again from a rate-limited API.

And one about the token. ENTSO-E reads it from the query string, so it is in
every request URL. It is added in one frame only (_send), never logged, and
a failure is re-raised as a fresh exception from outside that frame, so no
traceback can carry its local variables into CloudWatch.
"""

from __future__ import annotations

from datetime import date
from typing import TYPE_CHECKING

import httpx
from defusedxml import ElementTree as SafeET
from pydantic import SecretStr
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from energy.config import Settings
from energy.entsoe import day_ahead_params
from energy.layout import landing_key
from energy.logging_config import get_logger

if TYPE_CHECKING:
    from types_boto3_s3 import S3Client

log = get_logger(__name__)

RETRYABLE_STATUS = frozenset({429, 500, 502, 503, 504})
TOKEN_PARAM = "securityToken"
ACKNOWLEDGEMENT_MARKER = b"Acknowledgement_MarketDocument"


class TransientSourceError(RuntimeError):
    """ENTSO-E failed in a way worth retrying."""


class PermanentSourceError(RuntimeError):
    """ENTSO-E failed in a way that won't improve on retry."""


def _raise_for_status(response: httpx.Response) -> None:
    if response.status_code in RETRYABLE_STATUS:
        raise TransientSourceError(f"retryable status {response.status_code}")
    if response.status_code >= 400:
        raise PermanentSourceError(f"status {response.status_code}: {response.text[:200]}")


def _send(url: str, params: dict[str, str], token: SecretStr, timeout: float) -> httpx.Response:
    """The only frame that ever holds the token in clear."""
    query = {**params, TOKEN_PARAM: token.get_secret_value()}
    with httpx.Client(timeout=timeout) as client:
        return client.get(url, params=query)


def _redact(text: str, token: SecretStr) -> str:
    secret = token.get_secret_value()
    return text.replace(secret, "***") if secret else text


# A few quick retries inside the function; the state machine retries the
# whole task on top of this, minutes apart, so this stays well inside the
# function's timeout.
@retry(
    retry=retry_if_exception_type(TransientSourceError),
    wait=wait_exponential(multiplier=1, min=2, max=20),
    stop=stop_after_attempt(4),
    reraise=True,
)
def fetch(params: dict[str, str], token: SecretStr, settings: Settings) -> bytes:
    """GET ENTSO-E and return the body. Retries 429 and 5xx; fails fast on 4xx."""
    url = settings.source_base_url
    log.info("fetch.start", url=url, params=params)
    failure: str | None = None
    try:
        response = _send(url, params, token, settings.request_timeout_seconds)
    except httpx.TransportError as exc:
        failure = _redact(f"{type(exc).__name__}: {exc}", token)
    if failure is not None:
        # Raised here, outside the except block: the original exception, whose
        # traceback reaches _send's locals, is dropped rather than chained.
        raise TransientSourceError(f"transport error calling {url}: {failure}")

    _raise_for_status(response)
    log.info("fetch.ok", url=url, bytes=len(response.content))
    return response.content


def reject_acknowledgement(payload: bytes) -> None:
    """Refuse to land ENTSO-E's error envelope.

    Errors and "no data" come back as an Acknowledgement document, sometimes
    with HTTP 200. Landing keys are deterministic, so landing one would
    overwrite a good file for the same day with an error message.
    """
    if ACKNOWLEDGEMENT_MARKER in payload[:1024]:
        raise PermanentSourceError(
            f"ENTSO-E returned an Acknowledgement, not data: {acknowledgement_reason(payload)}"
        )


def acknowledgement_reason(payload: bytes) -> str:
    """ENTSO-E's own explanation, e.g. "999: No matching data found for ..."."""
    try:
        root = SafeET.fromstring(payload)
    except Exception:  # malformed, or defusedxml refusing an entity: show the start
        return payload[:400].decode("utf-8", errors="replace")
    reasons = [
        ": ".join(
            part
            for part in (
                (reason.findtext("{*}code") or "").strip(),
                (reason.findtext("{*}text") or "").strip(),
            )
            if part
        )
        for reason in root.findall(".//{*}Reason")
    ]
    return "; ".join(r for r in reasons if r) or payload[:400].decode("utf-8", errors="replace")


def extract(
    zone: str,
    eic: str,
    day: date,
    *,
    token: SecretStr,
    s3: S3Client,
    settings: Settings,
) -> tuple[str, int]:
    """Fetch one zone's day and land it. Returns (landing key, bytes).

    Safe to rerun: the same zone and day always land at the same key.
    """
    payload = fetch(day_ahead_params(eic, day), token, settings)
    reject_acknowledgement(payload)
    key = landing_key(zone, day)
    s3.put_object(Bucket=settings.bucket(), Key=key, Body=payload, ContentType="application/xml")
    log.info("land.ok", key=key, bytes=len(payload))
    return key, len(payload)
