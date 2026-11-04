"""Copying project 1's landed files into the lake: only what's missing, never
over a day the lake already has."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

import pytest

from energy import backfill
from energy.backfill import copy_new, landed_files
from tests.conftest import BUCKET, FIXTURES

if TYPE_CHECKING:
    from mypy_boto3_s3 import S3Client

DOCUMENT = (FIXTURES / "entsoe_a44_nl_20260924.xml").read_bytes()
ACK = (
    b'<?xml version="1.0" encoding="UTF-8"?>\n<Acknowledgement_MarketDocument>'
    b"<Reason><code>999</code><text>No matching data found</text></Reason>"
    b"</Acknowledgement_MarketDocument>"
)


def land(root: Path, relative: str, body: bytes = DOCUMENT) -> str:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body)
    return f"landing/{relative}"


@pytest.fixture
def project1(tmp_path: Path) -> Path:
    """A project 1 data/landing folder, with the things that must be left out."""
    land(tmp_path, "dataset=prices/zone=NL/year=2025/month=03/prices_NL_2025-03-14.xml")
    land(tmp_path, "dataset=prices/zone=BE/year=2025/month=03/prices_BE_2025-03-14.xml")
    # Project 1's first, single-zone layout: no zone folder.
    land(tmp_path, "dataset=prices/year=2025/month=01/prices_2025-01-01.xml")
    # A name that isn't a day.
    land(tmp_path, "dataset=prices/zone=NL/year=2025/month=03/prices_NL_latest.xml")
    # A file whose name and folder disagree.
    land(tmp_path, "dataset=prices/zone=NL/year=2025/month=04/prices_NL_2025-03-15.xml")
    # Another dataset.
    land(tmp_path, "dataset=weather/zone=NL/year=2025/month=03/weather_NL_2025-03-14.xml")
    return tmp_path


def lake(s3: S3Client) -> dict[str, bytes]:
    listing = s3.list_objects_v2(Bucket=BUCKET, Prefix="landing/")
    return {
        item["Key"]: s3.get_object(Bucket=BUCKET, Key=item["Key"])["Body"].read()
        for item in listing.get("Contents", [])
    }


def test_only_files_at_their_exact_lake_key_are_picked(project1: Path) -> None:
    assert list(landed_files(project1)) == [
        "landing/dataset=prices/zone=BE/year=2025/month=03/prices_BE_2025-03-14.xml",
        "landing/dataset=prices/zone=NL/year=2025/month=03/prices_NL_2025-03-14.xml",
    ]


def test_missing_days_are_copied_unmodified(project1: Path, s3: S3Client) -> None:
    result = copy_new(project1, s3=s3, bucket=BUCKET)
    assert len(result.copied) == 2
    assert lake(s3) == dict.fromkeys(result.copied, DOCUMENT)


def test_a_day_the_lake_has_is_never_overwritten(project1: Path, s3: S3Client) -> None:
    key = "landing/dataset=prices/zone=NL/year=2025/month=03/prices_NL_2025-03-14.xml"
    s3.put_object(Bucket=BUCKET, Key=key, Body=b"<the lake's own, newer copy>")
    result = copy_new(project1, s3=s3, bucket=BUCKET)
    assert result.already_there == [key]
    assert lake(s3)[key] == b"<the lake's own, newer copy>"


def test_copying_twice_copies_nothing_the_second_time(project1: Path, s3: S3Client) -> None:
    copy_new(project1, s3=s3, bucket=BUCKET)
    again = copy_new(project1, s3=s3, bucket=BUCKET)
    assert again.copied == []
    assert len(again.already_there) == 2


def test_an_acknowledgement_is_left_behind(tmp_path: Path, s3: S3Client) -> None:
    key = land(tmp_path, "dataset=prices/zone=AT/year=2025/month=03/prices_AT_2025-03-14.xml", ACK)
    result = copy_new(tmp_path, s3=s3, bucket=BUCKET)
    assert result.not_data == [key]
    assert lake(s3) == {}


def test_the_command_needs_project_1s_folder(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(SystemExit):
        backfill.main([str(tmp_path)])
    assert "is it project 1's data/landing?" in capsys.readouterr().err


def test_the_command_reports_what_it_did(
    project1: Path,
    s3: S3Client,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("ENERGY_LAKE_BUCKET", BUCKET)
    assert backfill.main([str(project1)]) == 0
    out = capsys.readouterr().out
    assert f"Copied 2 files to s3://{BUCKET}/landing/dataset=prices/" in out
    assert "Already in the lake, left as they are: 0" in out
