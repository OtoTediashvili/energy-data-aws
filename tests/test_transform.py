"""The transform function: dbt build inside Lambda.

dbt itself is replaced by a stand-in here; the real build runs against
Athena in `make dbt-build` and in the deployed function. What is tested is
everything around it: where dbt may write, what it runs, how a failure is
reported, and the lock swap that lets dbt start inside Lambda at all.
"""

from __future__ import annotations

import multiprocessing.synchronize
from dataclasses import dataclass, field
from multiprocessing.pool import ThreadPool
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest
from dbt.mp_context import get_mp_context

from energy import transform
from energy.config import Settings
from energy.transform import DbtBuildError, build_args, run, use_thread_locks


@pytest.fixture
def restore_locks(monkeypatch: pytest.MonkeyPatch) -> None:
    """use_thread_locks() changes the whole process: undo it after the test."""
    for name in ("Lock", "RLock"):
        monkeypatch.setattr(
            multiprocessing.synchronize, name, getattr(multiprocessing.synchronize, name)
        )


@dataclass
class Outcome:
    success: bool
    result: Any = None
    exception: BaseException | None = None


@dataclass
class FakeRunner:
    outcome: Outcome
    calls: list[list[str]] = field(default_factory=list)

    def invoke(self, args: list[str]) -> Outcome:
        self.calls.append(args)
        return self.outcome


def node(unique_id: str, status: str, message: str | None = None) -> SimpleNamespace:
    return SimpleNamespace(
        node=SimpleNamespace(unique_id=unique_id), status=status, message=message
    )


def built(*results: SimpleNamespace, success: bool = True) -> FakeRunner:
    return FakeRunner(Outcome(success=success, result=SimpleNamespace(results=list(results))))


SETTINGS = Settings(dbt_project_dir=Path("/var/task/dbt_project"), dbt_work_dir=Path("/tmp/dbt"))


def flag(args: list[str], name: str) -> str:
    return args[args.index(name) + 1]


def test_dbt_writes_only_under_tmp() -> None:
    """The image is read-only in Lambda: target/ and logs/ go to /tmp."""
    args = build_args(SETTINGS)
    assert args[0] == "build"
    assert flag(args, "--project-dir") == flag(args, "--profiles-dir") == "/var/task/dbt_project"
    assert flag(args, "--target-path") == "/tmp/dbt/target"
    assert flag(args, "--log-path") == "/tmp/dbt/logs"


def test_unit_tests_are_left_out_but_data_tests_run() -> None:
    args = build_args(SETTINGS)
    assert flag(args, "--exclude-resource-type") == "unit_test"
    assert "--select" not in args
    assert "--exclude" not in args


def test_a_clean_build_is_counted() -> None:
    runner = built(
        node("seed.energy.bidding_zones", "success"),
        node("model.energy.fct_daily_prices", "success"),
        node("test.energy.not_null_x", "pass"),
        node("test.energy.unique_x", "pass"),
    )
    summary = run(SETTINGS, runner)
    assert summary["counts"] == {"pass": 2, "success": 2}
    assert len(runner.calls) == 1


def test_a_failing_test_fails_the_function_and_names_the_test() -> None:
    runner = built(
        node("model.energy.fct_daily_prices", "success"),
        node(
            "test.energy.assert_fct_matches_staging",
            "fail",
            "Got 3 results, configured to fail if != 0\nsql: select ...",
        ),
        node("test.energy.unique_x", "pass"),
        success=False,
    )
    with pytest.raises(DbtBuildError) as caught:
        run(SETTINGS, runner)
    message = str(caught.value)
    assert message == (
        "test.energy.assert_fct_matches_staging (fail): Got 3 results, configured to fail if != 0"
    )


def test_a_failing_model_and_what_it_skipped() -> None:
    runner = built(
        node("model.energy.fct_daily_prices", "error", "NOT_SUPPORTED: Incorrect timestamp"),
        node("test.energy.unique_x", "skipped"),
        success=False,
    )
    with pytest.raises(DbtBuildError, match=r"fct_daily_prices \(error\): NOT_SUPPORTED"):
        run(SETTINGS, runner)


def test_a_dbt_that_cannot_start_says_why() -> None:
    runner = FakeRunner(
        Outcome(success=False, exception=RuntimeError("Could not find profile named 'energy'"))
    )
    with pytest.raises(DbtBuildError, match="dbt did not run: Could not find profile"):
        run(SETTINGS, runner)


def test_a_long_failure_list_is_cut_to_fit_an_error_message() -> None:
    runner = built(
        *(node(f"test.energy.t{i}", "fail", "x" * 1000) for i in range(50)), success=False
    )
    with pytest.raises(DbtBuildError) as caught:
        run(SETTINGS, runner)
    assert len(str(caught.value)) == transform.FAILURES_LIMIT


def test_the_handler_runs_dbt_with_the_function_settings(
    monkeypatch: pytest.MonkeyPatch, restore_locks: None, tmp_path: Path
) -> None:
    runners: list[FakeRunner] = []

    def fake_dbt_runner() -> FakeRunner:
        runner = built(node("model.energy.dim_bidding_zone", "success"))
        runners.append(runner)
        return runner

    monkeypatch.setattr("dbt.cli.main.dbtRunner", fake_dbt_runner)
    monkeypatch.setenv("ENERGY_DBT_PROJECT_DIR", str(tmp_path / "dbt"))
    monkeypatch.setenv("ENERGY_DBT_WORK_DIR", str(tmp_path / "work"))

    assert transform.handler({})["counts"] == {"success": 1}
    (runner,) = runners
    assert flag(runner.calls[0], "--target-path") == str(tmp_path / "work" / "target")


def test_without_shared_memory_dbt_needs_the_thread_locks(
    monkeypatch: pytest.MonkeyPatch, restore_locks: None
) -> None:
    """Lambda in miniature: a process where multiprocessing can't create a lock."""

    def no_shared_memory(*args: object, **kwargs: object) -> None:
        raise OSError(38, "Function not implemented")

    monkeypatch.setattr(multiprocessing.synchronize.SemLock, "__init__", no_shared_memory)

    # What dbt does first: a ThreadPool (its runner's pool is one) and its own locks.
    with pytest.raises(OSError, match="Function not implemented"):
        ThreadPool(2)
    with pytest.raises(OSError, match="Function not implemented"):
        get_mp_context().RLock()

    use_thread_locks()

    with get_mp_context().RLock(), get_mp_context().Lock():
        pass
    pool = ThreadPool(2)
    try:
        assert pool.map(lambda n: n * n, [1, 2, 3]) == [1, 4, 9]
    finally:
        pool.close()
        pool.join()
