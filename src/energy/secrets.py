"""The ENTSO-E token, from SSM Parameter Store.

Read at run time and kept in memory for as long as Lambda keeps the
container warm, so a day's four extracts make one SSM call, not four. It is
wrapped in a SecretStr: printed or logged by accident, it shows as '**********'.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from pydantic import SecretStr

if TYPE_CHECKING:
    from mypy_boto3_ssm import SSMClient

_cache: dict[str, SecretStr] = {}


def entsoe_token(ssm: SSMClient, parameter: str) -> SecretStr:
    if parameter not in _cache:
        response = ssm.get_parameter(Name=parameter, WithDecryption=True)
        value = response["Parameter"].get("Value", "")
        if not value:
            raise RuntimeError(f"SSM parameter {parameter} is empty")
        _cache[parameter] = SecretStr(value)
    return _cache[parameter]


def forget() -> None:
    """Drop the cached token (tests; a rotated token)."""
    _cache.clear()
