from __future__ import annotations

import sqlite3
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import pytest

from offroad_batman.jobs.array_io import encode_array
from offroad_batman.jobs.errors import (
    IdempotencyConflict,
    InvalidStateTransition,
    ReceiverBusy,
)
from offroad_batman.jobs.models import ComputationState
from offroad_batman.jobs.receiver.storage import JobStorage


def _input() -> bytes:
    return encode_array(np.arange(8, dtype=np.int16)).data


def _admit(storage: JobStorage, key: str, job_id: str):
    return storage.admit(
        idempotency_key=key,
        metadata={"operation": "test"},
        callback_url="http://ragnarhorn.mesh:8080/v1/callbacks",
        input_data=_input(),
        max_array_bytes=4096,
        job_id=job_id,
    )


def test_admission_is_durable_and_replay_precedes_busy_check(tmp_path: Path) -> None:
    storage = JobStorage(tmp_path)

    first = _admit(storage, "same-key", "job-one")
    replay = _admit(storage, "same-key", "different-unused-id")

    assert first.replayed is False
    assert replay.replayed is True
    assert replay.job.job_id == first.job.job_id
    assert replay.job.input_path.read_bytes() == _input()
    reopened = JobStorage(tmp_path).get_job(first.job.job_id)
    assert reopened.input_sha256 == first.job.input_sha256

    with sqlite3.connect(storage.database_path) as connection:
        assert connection.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 2


def test_idempotency_conflict_and_busy_slot(tmp_path: Path) -> None:
    storage = JobStorage(tmp_path)
    first = _admit(storage, "key-one", "job-one")

    with pytest.raises(IdempotencyConflict):
        storage.admit(
            idempotency_key="key-one",
            metadata={"operation": "different"},
            callback_url="http://ragnarhorn.mesh:8080/v1/callbacks",
            input_data=_input(),
            max_array_bytes=4096,
        )
    with pytest.raises(ReceiverBusy):
        _admit(storage, "key-two", "job-two")

    storage.set_computation_state(first.job.job_id, ComputationState.FAILED)
    second = _admit(storage, "key-two", "job-two")
    assert second.job.job_id == "job-two"


def test_concurrent_submissions_cannot_both_reserve_slot(tmp_path: Path) -> None:
    storage = JobStorage(tmp_path)

    def submit(index: int) -> str:
        try:
            _admit(storage, f"key-{index}", f"job-{index}")
        except ReceiverBusy:
            return "busy"
        return "accepted"

    with ThreadPoolExecutor(max_workers=2) as executor:
        outcomes = list(executor.map(submit, (1, 2)))

    assert sorted(outcomes) == ["accepted", "busy"]


def test_success_cannot_overwrite_concurrent_cancellation(tmp_path: Path) -> None:
    storage = JobStorage(tmp_path)
    job = _admit(storage, "key-one", "job-one").job
    storage.set_computation_state(job.job_id, ComputationState.RUNNING)
    storage.set_computation_state(job.job_id, ComputationState.CANCELLING)
    temporary_result = job.input_path.parent / "result.npy.worker.tmp"
    temporary_result.write_bytes(_input())

    with pytest.raises(InvalidStateTransition):
        storage.complete_success(
            job.job_id,
            temporary_result,
            max_array_bytes=4096,
            retention_seconds=3600,
        )

    current = storage.get_job(job.job_id)
    assert current.computation_state is ComputationState.CANCELLING
    assert current.result_path is None
