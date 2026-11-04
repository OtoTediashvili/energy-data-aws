"""Copy project 1's landed ENTSO-E files into the lake, for the backfill.

Project 1 keeps the same layout in its data/landing folder, so a file's path
there is its key here. The backfill state machine then parses everything in
landing/ and dbt rebuilds the marts.

Only days the lake doesn't have are copied. A day already in landing/ was
fetched by this pipeline, maybe later and with a revision, and the one raw
copy of a day is never replaced by an older one. Acknowledgements (ENTSO-E's
"no data" envelope) are left behind too, as extract would have refused them.

    uv run python -m energy.backfill ~/projects/de-pipeline/data/landing
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import TYPE_CHECKING

import boto3

from energy.config import Settings
from energy.extract import PermanentSourceError, reject_acknowledgement
from energy.layout import DATASET, LANDING, landing_key

if TYPE_CHECKING:
    from mypy_boto3_s3 import S3Client

PREFIX = f"{LANDING}/dataset={DATASET}/"


@dataclass
class Copied:
    """What copy_new did, as lake keys."""

    copied: list[str] = field(default_factory=list)
    already_there: list[str] = field(default_factory=list)
    not_data: list[str] = field(default_factory=list)


def landed_files(root: Path) -> dict[str, Path]:
    """Project 1's price files under root, by the key each one gets in the lake.

    A file counts only if its path is exactly the key this pipeline would
    give it: older single-zone files (no zone= folder) and anything else in
    the folder are left out.
    """
    files: dict[str, Path] = {}
    for path in sorted((root / f"dataset={DATASET}").glob("zone=*/year=*/month=*/*.xml")):
        zone, _, day = path.stem.removeprefix(f"{DATASET}_").rpartition("_")
        try:
            key = landing_key(zone, date.fromisoformat(day))
        except ValueError:
            continue
        if key == f"{LANDING}/{path.relative_to(root).as_posix()}":
            files[key] = path
    return files


def lake_keys(s3: S3Client, bucket: str) -> set[str]:
    keys: set[str] = set()
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=PREFIX):
        keys.update(item["Key"] for item in page.get("Contents", []))
    return keys


def copy_new(root: Path, *, s3: S3Client, bucket: str, threads: int = 8) -> Copied:
    """Upload the files the lake doesn't have yet; never overwrite one it has."""
    result = Copied()
    files = landed_files(root)
    existing = lake_keys(s3, bucket)
    to_copy: dict[str, bytes] = {}
    for key, path in files.items():
        if key in existing:
            result.already_there.append(key)
            continue
        payload = path.read_bytes()
        try:
            reject_acknowledgement(payload)
        except PermanentSourceError:
            result.not_data.append(key)
            continue
        to_copy[key] = payload

    def put(key: str) -> str:
        s3.put_object(Bucket=bucket, Key=key, Body=to_copy[key], ContentType="application/xml")
        return key

    with ThreadPoolExecutor(max_workers=threads) as pool:
        result.copied = sorted(pool.map(put, to_copy))
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else None)
    parser.add_argument("landing", type=Path, help="project 1's data/landing folder")
    args = parser.parse_args(argv)
    if not (args.landing / f"dataset={DATASET}").is_dir():
        parser.error(
            f"{args.landing} has no dataset={DATASET} folder: is it project 1's data/landing?"
        )

    bucket = Settings().bucket()
    result = copy_new(args.landing, s3=boto3.client("s3"), bucket=bucket)
    print(f"Copied {len(result.copied)} files to s3://{bucket}/{PREFIX}")
    print(f"Already in the lake, left as they are: {len(result.already_there)}")
    if result.not_data:
        print(f"Acknowledgements, not prices, not copied: {len(result.not_data)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
