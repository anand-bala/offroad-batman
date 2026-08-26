from __future__ import annotations

import queue
import threading
import time
from pathlib import Path

import numpy as np
import pytest

from offroad_batman.jobs.array_io import decode_array, encode_array
from offroad_batman.jobs.config import ReceiverSettings
from offroad_batman.jobs.errors import ErrorCode
from offroad_batman.jobs.models import ComputationState, ResultState
from offroad_batman.jobs.receiver.storage import JobStorage
from offroad_batman.jobs.receiver.supervisor import RunningWorker, WorkerSupervisor


def _admit(storage: JobStorage, job_id: str = "job-one") -> str:
    result = storage.admit(
        idempotency_key=f"key-{job_id}",
        metadata={},
        callback_url="http://ragnarhorn.mesh:8080/v1/callbacks",
        input_data=encode_array(np.arange(4, dtype=np.int16)).data,
        max_array_bytes=4096,
        job_id=job_id,
    )
    return result.job.job_id


def _settings(
    tmp_path: Path,
    processor: str,
    **overrides: float | int,
) -> ReceiverSettings:
    values: dict[str, object] = {
        "processor": processor,
        "state_directory": tmp_path,
        "heartbeat_interval_seconds": 0.02,
        "worker_startup_timeout_seconds": 5,
        "runtime_heartbeat_timeout_seconds": 0.5,
        "progress_timeout_seconds": 0.5,
        "cancellation_grace_seconds": 0.1,
        "termination_grace_seconds": 0.1,
        "post_outcome_exit_timeout_seconds": 1,
        "monitor_interval_seconds": 0.01,
        "max_array_bytes": 4096,
    }
    values.update(overrides)
    return ReceiverSettings(**values)


def test_spawned_worker_publishes_valid_result(tmp_path: Path) -> None:
    storage = JobStorage(tmp_path)
    job_id = _admit(storage)
    supervisor = WorkerSupervisor(
        storage,
        _settings(tmp_path, "tests.fixtures.processors:double"),
    )

    outcome = supervisor.run(job_id)

    assert outcome.state is ComputationState.SUCCEEDED
    job = storage.get_job(job_id)
    assert job.result_state is ResultState.AVAILABLE
    assert job.result_path is not None
    np.testing.assert_array_equal(
        decode_array(job.result_path.read_bytes()),
        np.arange(4, dtype=np.int16) * 2,
    )


@pytest.mark.parametrize(
    ("processor", "expected_code"),
    [
        ("tests.fixtures.processors:fail", ErrorCode.WORKER_EXCEPTION),
        ("tests.fixtures.processors:crash", ErrorCode.WORKER_CRASHED),
        ("tests.fixtures.processors:object_result", ErrorCode.INVALID_RESULT),
    ],
)
def test_worker_failures_are_structured(
    tmp_path: Path,
    processor: str,
    expected_code: ErrorCode,
) -> None:
    storage = JobStorage(tmp_path)
    job_id = _admit(storage)

    outcome = WorkerSupervisor(storage, _settings(tmp_path, processor)).run(job_id)

    assert outcome.state is ComputationState.FAILED
    assert outcome.error is not None
    assert outcome.error.code is expected_code
    job = storage.get_job(job_id)
    assert job.error is not None
    assert job.error.code is expected_code


@pytest.mark.parametrize("cooperative", [True, False])
def test_cancellation_ends_cooperative_and_uncooperative_workers(
    tmp_path: Path,
    cooperative: bool,
) -> None:
    processor = (
        "tests.fixtures.processors:cooperative_wait"
        if cooperative
        else "tests.fixtures.processors:uncooperative_wait"
    )
    storage = JobStorage(tmp_path)
    job_id = _admit(storage)
    supervisor = WorkerSupervisor(storage, _settings(tmp_path, processor))
    worker = supervisor.start(job_id)
    timer = threading.Timer(0.15, worker.cancel)
    timer.start()
    try:
        outcome = supervisor.wait(worker)
    finally:
        timer.cancel()

    assert outcome.state is ComputationState.CANCELLED
    assert worker.process.is_alive() is False


def test_progress_timeout_terminates_worker(tmp_path: Path) -> None:
    storage = JobStorage(tmp_path)
    job_id = _admit(storage)
    settings = _settings(
        tmp_path,
        "tests.fixtures.processors:no_progress",
        progress_timeout_seconds=0.1,
    )

    outcome = WorkerSupervisor(storage, settings).run(job_id)

    assert outcome.state is ComputationState.FAILED
    assert outcome.error is not None
    assert outcome.error.code is ErrorCode.PROGRESS_TIMEOUT


def test_runtime_heartbeat_timeout_terminates_worker(tmp_path: Path) -> None:
    storage = JobStorage(tmp_path)
    job_id = _admit(storage)
    settings = _settings(
        tmp_path,
        "tests.fixtures.processors:no_progress",
        heartbeat_interval_seconds=1,
        runtime_heartbeat_timeout_seconds=0.1,
        progress_timeout_seconds=2,
    )

    outcome = WorkerSupervisor(storage, settings).run(job_id)

    assert outcome.state is ComputationState.FAILED
    assert outcome.error is not None
    assert outcome.error.code is ErrorCode.WORKER_UNRESPONSIVE


def test_worker_startup_timeout_is_distinct_from_runtime_timeout(
    tmp_path: Path,
) -> None:
    storage = JobStorage(tmp_path)
    job_id = _admit(storage)
    settings = _settings(
        tmp_path,
        "tests.fixtures.processors:double",
        worker_startup_timeout_seconds=0.001,
        runtime_heartbeat_timeout_seconds=5,
        progress_timeout_seconds=5,
    )

    outcome = WorkerSupervisor(storage, settings).run(job_id)

    assert outcome.state is ComputationState.FAILED
    assert outcome.error is not None
    assert outcome.error.code is ErrorCode.WORKER_STARTUP_TIMEOUT
    assert "startup" in outcome.error.message


class _ExitedProcess:
    exitcode = 0

    def is_alive(self) -> bool:
        return False

    def join(self, timeout: float | None = None) -> None:
        del timeout


def test_post_exit_drain_skips_lifecycle_messages_before_outcome(
    tmp_path: Path,
) -> None:
    storage = JobStorage(tmp_path)
    job_id = _admit(storage)
    storage.set_computation_state(job_id, ComputationState.RUNNING)
    messages: queue.Queue[tuple[str, object]] = queue.Queue()
    messages.put(("runtime", time.monotonic()))
    messages.put(("progress", time.monotonic()))
    messages.put(
        (
            "outcome",
            {
                "kind": "failed",
                "message": "reported failure",
                "traceback": "fixture traceback",
            },
        )
    )
    worker = RunningWorker(
        job_id=job_id,
        process=_ExitedProcess(),
        cancellation=threading.Event(),
        messages=messages,
        temporary_result_path=tmp_path / "unused-result.tmp",
        started_at=time.monotonic(),
        last_runtime_heartbeat=time.monotonic(),
        last_progress_heartbeat=time.monotonic(),
    )

    outcome = WorkerSupervisor(
        storage,
        _settings(tmp_path, "tests.fixtures.processors:double"),
    ).wait(worker)

    assert outcome.state is ComputationState.FAILED
    assert outcome.error is not None
    assert outcome.error.code is ErrorCode.WORKER_EXCEPTION


def test_reported_outcome_survives_slow_normal_child_exit(tmp_path: Path) -> None:
    storage = JobStorage(tmp_path)
    job_id = _admit(storage)
    settings = _settings(
        tmp_path,
        "tests.fixtures.processors:delayed_process_exit",
        termination_grace_seconds=0.05,
        post_outcome_exit_timeout_seconds=1,
    )

    outcome = WorkerSupervisor(storage, settings).run(job_id)

    assert outcome.state is ComputationState.SUCCEEDED
    assert storage.get_job(job_id).result_state is ResultState.AVAILABLE
