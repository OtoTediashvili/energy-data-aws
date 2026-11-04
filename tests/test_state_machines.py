"""The state machines, checked before AWS sees them.

The definitions in infra/state_machines/ are rendered with the values
Terraform passes, then their JSONata expressions are evaluated on the inputs
the real runs get: the schedule's time, a failed zone, a landed file's key.
A mistake here would otherwise show up as a failed run, a day later.
"""

from __future__ import annotations

import csv
import json
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import jsonata
import pytest

from energy import extract, transform

ROOT = Path(__file__).resolve().parents[1]
ZONES = list(csv.DictReader((ROOT / "dbt" / "seeds" / "bidding_zones.csv").open()))
FUNCTION = "arn:aws:lambda:eu-central-1:123456789012:function:energy-{}"


def render(name: str) -> dict[str, Any]:
    """The definition as Terraform's templatefile() renders it."""
    values = {
        "extract": FUNCTION.format("extract"),
        "parse": FUNCTION.format("parse"),
        "transform": FUNCTION.format("transform"),
        "bucket": "energy-lake-123456789012",
        "zones": json.dumps(
            [{"zone": z["country_code"], "eic": z["bidding_zone_eic"]} for z in ZONES]
        ),
        "eic_by_zone": json.dumps({z["country_code"]: z["bidding_zone_eic"] for z in ZONES}),
    }
    text = (ROOT / "infra" / "state_machines" / f"{name}.asl.json").read_text()
    for key, value in values.items():
        text = text.replace("${" + key + "}", value)
    assert "${" not in text, "the template uses a value Terraform doesn't pass"
    definition: dict[str, Any] = json.loads(text)
    return definition


DAILY = render("daily")
BACKFILL = render("backfill")
ZONE_MAP = DAILY["States"]["Every zone"]
ZONE_STATES = ZONE_MAP["ItemProcessor"]["States"]
FILE_MAP = BACKFILL["States"]["Every landed file"]


def evaluate(expression: str, states: dict[str, Any], **variables: Any) -> Any:
    """One {% ... %} expression, with $states and the run's variables bound."""
    assert expression.startswith("{%") and expression.endswith("%}"), expression
    compiled = jsonata.Jsonata(expression[2:-2].strip())
    compiled.assign("states", states)
    for name, value in variables.items():
        compiled.assign(name, value)
    return compiled.evaluate(None)


def all_states(states: dict[str, Any]) -> Iterator[tuple[dict[str, Any], str, dict[str, Any]]]:
    """Every state with its siblings, Map item processors included."""
    for name, state in states.items():
        yield states, name, state
        if "ItemProcessor" in state:
            yield from all_states(state["ItemProcessor"]["States"])


# ---------------------------------------------------------------- structure


@pytest.mark.parametrize("definition", [DAILY, BACKFILL], ids=["daily", "backfill"])
def test_every_next_leads_to_a_state(definition: dict[str, Any]) -> None:
    assert definition["StartAt"] in definition["States"]
    for siblings, name, state in all_states(definition["States"]):
        targets = [state.get("Next"), state.get("Default")]
        targets += [choice["Next"] for choice in state.get("Choices", [])]
        targets += [catch["Next"] for catch in state.get("Catch", [])]
        for target in filter(None, targets):
            assert target in siblings, f"{name} -> {target}"


def test_the_daily_run_covers_every_zone_in_the_seed() -> None:
    assert [item["zone"] for item in ZONE_MAP["Items"]] == [z["country_code"] for z in ZONES]


def test_the_errors_the_state_machine_waits_on_are_the_ones_extract_raises() -> None:
    """Step Functions matches a Python error by its class name: a rename in
    extract.py would silently turn a wait into a failure."""
    retried = {name for rule in ZONE_STATES["Extract"]["Retry"] for name in rule["ErrorEquals"]}
    assert extract.NoMatchingDataError.__name__ in retried
    assert extract.TransientSourceError.__name__ in retried
    assert extract.PermanentSourceError.__name__ not in retried


def test_unpublished_prices_are_waited_for_over_two_hours() -> None:
    (rule,) = [
        r for r in ZONE_STATES["Extract"]["Retry"] if "NoMatchingDataError" in r["ErrorEquals"]
    ]
    waits = [rule["IntervalSeconds"] * rule["BackoffRate"] ** n for n in range(rule["MaxAttempts"])]
    assert sum(waits) / 60 == 20 + 40 + 80


@pytest.mark.parametrize("definition", [DAILY, BACKFILL], ids=["daily", "backfill"])
def test_a_failed_dbt_build_is_not_retried(definition: dict[str, Any]) -> None:
    """A failing data test fails the same way twice: report it at once."""
    retried = {
        n for rule in definition["States"]["Transform"]["Retry"] for n in rule["ErrorEquals"]
    }
    assert transform.DbtBuildError.__name__ not in retried
    assert "States.ALL" not in retried


# --------------------------------------------------------------- the day


@pytest.mark.parametrize(
    ("given", "expected"),
    [
        ({"scheduled_time": "2026-11-03T13:17:00Z"}, "2026-11-03"),
        ({"logical_date": "2026-10-25"}, "2026-10-25"),
        ({}, "2026-11-04"),
    ],
    ids=["the schedule", "a date given", "by hand without a date"],
)
def test_the_run_picks_its_day(given: dict[str, Any], expected: str) -> None:
    states = {
        "input": given,
        "context": {"Execution": {"StartTime": "2026-11-04T08:00:01.250Z"}},
    }
    day = evaluate(DAILY["States"]["Pick the day"]["Output"]["logical_date"], states)
    assert day == expected


def test_each_zone_gets_its_eic_and_the_day() -> None:
    nl = {"zone": "NL", "eic": "10YNL----------L"}
    states = {"input": {"logical_date": "2026-11-03"}, "context": {"Map": {"Item": {"Value": nl}}}}
    selected = {key: evaluate(value, states) for key, value in ZONE_MAP["ItemSelector"].items()}
    assert selected == {**nl, "logical_date": "2026-11-03"}


# ------------------------------------------------------ a zone that fails


DELIVERY = {"zone": "BE", "eic": "10YBE----------2", "logical_date": "2026-11-03"}
UNPUBLISHED = {
    "Error": "NoMatchingDataError",
    "Cause": json.dumps({"errorMessage": "ENTSO-E returned an Acknowledgement", "x": "y" * 900}),
}


def caught(state: str) -> dict[str, Any]:
    (catch,) = ZONE_STATES[state]["Catch"]
    result: dict[str, Any] = evaluate(
        catch["Output"], {"input": DELIVERY, "errorOutput": UNPUBLISHED}
    )
    return result


def test_a_failed_zone_is_recorded_not_raised() -> None:
    failed = caught("Extract")
    assert failed["zone"] == "BE"
    assert failed["failed_in"] == "extract"
    assert failed["error"] == "NoMatchingDataError"
    assert len(failed["cause"]) == 500
    assert caught("Parse")["failed_in"] == "parse"


def zones_failed(deliveries: list[dict[str, Any]]) -> tuple[bool, str]:
    choice = DAILY["States"]["Did every zone arrive?"]["Choices"][0]
    failed = evaluate(choice["Condition"], {}, deliveries=deliveries)
    cause = evaluate(DAILY["States"]["Some zones failed"]["Cause"], {}, deliveries=deliveries)
    return failed, cause


def test_one_failed_zone_fails_the_run_and_names_the_zone() -> None:
    delivered = [
        {**DELIVERY, "zone": zone, "parsed_key": f"parsed/{zone}", "rows": 192}
        for zone in ("NL", "AT", "CZ")
    ]
    failed, cause = zones_failed([*delivered, caught("Extract")])
    assert failed is True
    assert cause == "BE 2026-11-03: NoMatchingDataError in extract"


def test_two_failed_zones_are_both_named() -> None:
    other = {**caught("Parse"), "zone": "AT", "error": "EntsoeParseError"}
    _, cause = zones_failed([caught("Extract"), other])
    assert cause == (
        "BE 2026-11-03: NoMatchingDataError in extract; AT 2026-11-03: EntsoeParseError in parse"
    )


def test_a_run_where_every_zone_arrived_succeeds() -> None:
    delivered = [{**DELIVERY, "zone": z["country_code"], "rows": 192} for z in ZONES]
    failed, _ = zones_failed(delivered)
    assert failed is False


# ----------------------------------------------------------------- backfill


def test_a_landed_key_becomes_its_zone_and_day() -> None:
    key = "landing/dataset=prices/zone=NL/year=2025/month=03/prices_NL_2025-03-14.xml"
    states = {
        "input": render("backfill")["States"]["Zones"]["Output"],
        "context": {"Map": {"Item": {"Value": {"Key": key, "Size": 28860}}}},
    }
    selected = {key: evaluate(value, states) for key, value in FILE_MAP["ItemSelector"].items()}
    assert selected == {
        "key": key,
        "zone": "NL",
        "eic": "10YNL----------L",
        "logical_date": "2025-03-14",
    }


def test_the_backfill_reads_only_the_prices_in_landing() -> None:
    assert FILE_MAP["ItemReader"]["Arguments"]["Prefix"] == "landing/dataset=prices/"


def files_failed(results: list[dict[str, Any]]) -> tuple[bool, str]:
    assign = FILE_MAP["Assign"]
    files = evaluate(assign["files"], {"result": results})
    failures = evaluate(assign["failures"], {"result": results})
    choice = BACKFILL["States"]["Did every file parse?"]["Choices"][0]
    failed = evaluate(choice["Condition"], {}, failures=failures)
    cause = evaluate(
        BACKFILL["States"]["Some files failed"]["Cause"], {}, failures=failures, files=files
    )
    return failed, cause


def test_one_bad_file_fails_the_backfill_after_the_rest_are_built() -> None:
    results = [{"rows": 192}] * 30 + [{"key": "landing/x.xml", "error": "EntsoeParseError"}]
    failed, cause = files_failed(results)
    assert failed is True
    assert cause == "1 of 31 files failed, first ones: landing/x.xml (EntsoeParseError)"


def test_many_bad_files_are_counted_and_the_first_ten_named() -> None:
    results = [{"key": f"landing/{n}.xml", "error": "EntsoeParseError"} for n in range(25)]
    _, cause = files_failed(results)
    assert cause.startswith("25 of 25 files failed, first ones: landing/0.xml")
    assert cause.count("EntsoeParseError") == 10


def test_a_clean_backfill_succeeds() -> None:
    failed, _ = files_failed([{"rows": 192}] * 3)
    assert failed is False
