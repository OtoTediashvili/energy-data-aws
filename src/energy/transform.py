"""Transform: `dbt build` inside the transform function, after the day's deliveries.

The same dbt project and profile as `make dbt-build`. Three things differ,
because this runs inside Lambda:

- The image is read-only, so dbt writes its target/ and logs/ under /tmp.
- Lambda has no shared memory (/dev/shm), and multiprocessing's locks need
  it. dbt creates such locks although it runs its work in threads, so its
  first query would fail with "OSError: [Errno 38] Function not
  implemented". use_thread_locks() swaps them for thread locks first.
- Unit tests are left out. They test the SQL, not the data, and they ran in
  CI and in `make dbt-build`. Every data test still runs, so bad data fails
  the build, and the state machine reports it.

This module is the transform image's handler and imports dbt, which the
ingestion image doesn't have; energy.handlers never imports it.
"""

from __future__ import annotations

import multiprocessing.synchronize
import threading
import time
from collections import Counter
from collections.abc import Callable, Sequence
from typing import Any, Protocol

from energy.config import Settings
from energy.logging_config import configure_logging, get_logger

log = get_logger(__name__)

# dbt's result statuses that fail a build: models and seeds report "error",
# tests "fail" (or "error" if the test's query itself broke).
FAILED = frozenset({"error", "fail"})
MESSAGE_LIMIT = 300
FAILURES_LIMIT = 3000


class DbtBuildError(RuntimeError):
    """dbt build finished with errors or failing tests; the message names them."""


class RunnerOutcome(Protocol):
    """What dbt's programmatic runner returns (dbtRunnerResult)."""

    @property
    def success(self) -> bool: ...

    @property
    def exception(self) -> BaseException | None: ...

    @property
    def result(self) -> Any: ...


class Runner(Protocol):
    """dbt's dbtRunner, or a stand-in in the tests."""

    def invoke(self, args: list[str]) -> RunnerOutcome: ...


def use_thread_locks() -> None:
    """Make multiprocessing's Lock and RLock plain thread locks, in this process.

    Safe for dbt: its pool is a ThreadPool, and nothing it locks is shared
    with another process. Every multiprocessing lock is created through these
    two names at the moment it's needed, so swapping them here covers dbt's
    own locks and the queue inside its thread pool alike.
    """
    factories: dict[str, Callable[..., object]] = {
        "Lock": lambda **_: threading.Lock(),
        "RLock": lambda **_: threading.RLock(),
    }
    for name, factory in factories.items():
        setattr(multiprocessing.synchronize, name, factory)


def build_args(settings: Settings) -> list[str]:
    """The function's build: every model, seed and data test; no unit tests."""
    return [*dbt_args("build", settings), "--exclude-resource-type", "unit_test"]


def dbt_args(command: str, settings: Settings) -> list[str]:
    """Any dbt command as the function runs it: its project, writing only to /tmp.

    CI uses it with `parse` to check the transform image read-only.
    """
    work = settings.dbt_work_dir
    return [
        command,
        "--project-dir",
        str(settings.dbt_project_dir),
        "--profiles-dir",
        str(settings.dbt_project_dir),
        "--target-path",
        str(work / "target"),
        "--log-path",
        str(work / "logs"),
        "--no-use-colors",
        "--no-send-anonymous-usage-stats",
    ]


def _first_line(message: str | None) -> str:
    lines = (message or "").strip().splitlines()
    return lines[0][:MESSAGE_LIMIT] if lines else ""


def run(settings: Settings, runner: Runner) -> dict[str, Any]:
    """Run dbt build and summarise it. Raises DbtBuildError if anything failed."""
    started = time.monotonic()
    outcome = runner.invoke(build_args(settings))
    if outcome.exception is not None:
        # dbt couldn't run at all: no profile, no connection, a parse error.
        raise DbtBuildError(f"dbt did not run: {outcome.exception}") from outcome.exception

    results: Sequence[Any] = getattr(outcome.result, "results", [])
    counts = Counter(str(result.status) for result in results)
    summary: dict[str, Any] = {
        "counts": dict(sorted(counts.items())),
        "seconds": round(time.monotonic() - started, 1),
    }
    if not outcome.success:
        failures = "; ".join(
            f"{result.node.unique_id} ({result.status}): {_first_line(result.message)}"
            for result in results
            if str(result.status) in FAILED
        )
        log.error("transform.failed", **summary)
        raise DbtBuildError((failures or "dbt build failed")[:FAILURES_LIMIT])
    return summary


def handler(event: dict[str, Any], context: object = None) -> dict[str, Any]:
    """Lambda entry point. The event is ignored: dbt works out what changed."""
    settings = Settings()
    configure_logging(settings.log_level, settings.log_json)
    use_thread_locks()
    from dbt.cli.main import dbtRunner  # the transform image has dbt; the tests mock it

    log.info("transform.start", project=str(settings.dbt_project_dir))
    summary = run(settings, dbtRunner())
    log.info("transform.ok", **summary)
    return summary
