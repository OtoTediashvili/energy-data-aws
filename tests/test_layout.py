"""Keys in the lake: deterministic, path-safe, and project 1's layout exactly."""

from __future__ import annotations

from datetime import date

import pytest

from energy.layout import landing_key, parsed_key, validate_eic, validate_zone_key

DAY = date(2026, 9, 24)


def test_landing_key_matches_project_1_data_folder() -> None:
    """Project 1 wrote data/landing/<this>; its history copies over unchanged."""
    assert landing_key("NL", DAY) == (
        "landing/dataset=prices/zone=NL/year=2026/month=09/prices_NL_2026-09-24.xml"
    )


def test_parsed_key_mirrors_the_landing_key() -> None:
    assert parsed_key("NL", DAY) == (
        "parsed/dataset=prices/zone=NL/year=2026/month=09/prices_NL_2026-09-24.parquet"
    )


def test_keys_are_a_pure_function_of_zone_and_day() -> None:
    """Running a day again must overwrite its file, never add another."""
    assert landing_key("BE", DAY) == landing_key("BE", DAY)
    assert landing_key("BE", DAY) != landing_key("NL", DAY)
    assert landing_key("BE", DAY) != landing_key("BE", date(2026, 9, 25))


@pytest.mark.parametrize("bad", ["../x", "NL/BE", "nl", "", "A" * 17, "N L"])
def test_unsafe_zone_keys_are_refused(bad: str) -> None:
    with pytest.raises(ValueError, match="invalid zone key"):
        landing_key(bad, DAY)
    with pytest.raises(ValueError):
        validate_zone_key(bad)


@pytest.mark.parametrize("good", ["10YNL----------L", "10YAT-APG------L", "10YCZ-CEPS-----N"])
def test_real_eic_codes_pass(good: str) -> None:
    assert validate_eic(good) == good


@pytest.mark.parametrize("bad", ["10YNL", "10ynl----------l", "10YNL----------L/"])
def test_malformed_eic_codes_are_refused(bad: str) -> None:
    with pytest.raises(ValueError, match="invalid EIC"):
        validate_eic(bad)
