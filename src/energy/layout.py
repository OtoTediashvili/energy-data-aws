"""Where each file lives in the lake.

The same layout as project 1's data/ folder, under an S3 prefix instead of a
folder:

    landing/dataset=prices/zone=NL/year=2026/month=09/prices_NL_2026-09-24.xml
    parsed/dataset=prices/zone=NL/year=2026/month=09/prices_NL_2026-09-24.parquet

So project 1's landed history copies over as it is (`aws s3 sync`), and the
Glue table over parsed/ finds zone, year and month in the path.

A key is a pure function of zone and day: running a day again overwrites
its one file instead of adding a second. The zone key ends up in the path,
so it is validated: "../x" or "NL/BE" would write outside its partition.
"""

from __future__ import annotations

import re
from datetime import date

DATASET = "prices"
LANDING = "landing"
PARSED = "parsed"

_ZONE_KEY = re.compile(r"^[A-Z0-9_]{1,16}$")
# Energy Identification Codes are 16 characters: digits, letters and dashes.
_EIC = re.compile(r"^[0-9A-Z-]{16}$")


def validate_zone_key(key: str) -> str:
    """Return the key unchanged, or raise if it is not path-safe."""
    if not _ZONE_KEY.match(key):
        raise ValueError(f"invalid zone key {key!r}: expected 1-16 characters of A-Z, 0-9, _")
    return key


def validate_eic(code: str) -> str:
    if not _EIC.match(code):
        raise ValueError(f"invalid EIC code {code!r}: expected 16 characters of 0-9, A-Z, -")
    return code


def object_key(stage: str, zone: str, day: date, suffix: str) -> str:
    """stage is the lake's layer (landing, parsed); zone the bidding zone key."""
    validate_zone_key(zone)
    return (
        f"{stage}/dataset={DATASET}/zone={zone}/year={day.year:04d}/month={day.month:02d}"
        f"/{DATASET}_{zone}_{day.isoformat()}{suffix}"
    )


def landing_key(zone: str, day: date) -> str:
    """Raw XML exactly as ENTSO-E sent it."""
    return object_key(LANDING, zone, day, ".xml")


def parsed_key(zone: str, day: date) -> str:
    """The typed Parquet parsed from the landing file of the same zone and day."""
    return object_key(PARSED, zone, day, ".parquet")
