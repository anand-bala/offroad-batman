"""Parent-side subprocess lifecycle and heartbeat supervision."""

from __future__ import annotations

import multiprocessing as mp
import queue
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

from ..config import ReceiverSettings
from ..errors import ArrayValidationError, ErrorCode, InvalidStateTransition
from ..models import ComputationState, ErrorInfo
from .storage import JobRecord, JobStorage
from .worker import run_worker


@dataclass(frozen=True)
class WorkerOutcome:
    state: ComputationState
    error: ErrorInfo | None = None
    result_path: Path | None = None
    result_size_bytes: int | None = None
    result_sha256: str | None = None


@dataclass
class RunningWorker:
    job_id: str
    process: Any
    cancellation: Any
    messages: Any
    temporary_result_path: Path
    started_at: float
    last_runtime_heartbeat: float
    last_progress_heartbeat: float
    received_runtime_heartbeat: bool = False
    processor_started: bool = False
    cancellation_started_at: float | None = None

    def cancel(self) -> None:
        """Request cooperative cancellation without blocking the caller."""

        self.cancellation.set()


class WorkerSupervisor:
    """Run and monitor one spawned processor at a time."""

    def __init__(self, storage: JobStorage, settings: ReceiverSettings) -> None:
        self.storage = storage
        self.settings = settings
        self._context = mp.get_context("spawn")

    def start(self, job_id: str) -> RunningWorker:
        """Transition an admitted job to running and spawn its worker."""

        job = self.storage.get_job(job_id)
        if job.computation_state is not ComputationState.ACCEPTED:
            raise ValueError("only an accepted job can be started")
        temporary_result_path = job.input_path.parent / "result.npy.worker.tmp"
        temporary_result_path.unlink(missing_ok=True)
        cancellation = self._context.Event()
        messages = self._context.Queue()
        process = self._context.Process(
            target=run_worker,
            args=(
                self.settings.processor,
                job.metadata,
                str(job.input_path),
                str(temporary_result_path),
                cancellation,
                messages,
                self.settings.heartbeat_interval_seconds,
                self.settings.max_array_bytes,
            ),
            name=f"manet-job-{job_id}",
        )
        self.storage.set_computation_state(job_id, ComputationState.RUNNING)
        started_at = time.monotonic()
        try:
            process.start()
        except BaseException:
            error = ErrorInfo(
                code=ErrorCode.WORKER_CRASHED,
                message="worker process could not be started",
                retryable=False,
            )
            self.storage.set_computation_state(
                job_id,
                ComputationState.FAILED,
                error=error,
            )
            self._close_queue(messages)
            raise
        return RunningWorker(
            job_id=job_id,
            process=process,
            cancellation=cancellation,
            messages=messages,
            temporary_result_path=temporary_result_path,
            started_at=started_at,
            last_runtime_heartbeat=started_at,
            last_progress_heartbeat=started_at,
        )

    def run(self, job_id: str) -> WorkerOutcome:
        """Start and synchronously wait for one worker."""

        return self.wait(self.start(job_id))

    def wait(self, worker: RunningWorker) -> WorkerOutcome:
        """Monitor a worker until success, failure, or cancellation is durable."""

        try:
            return self._wait_for_outcome(worker)
        finally:
            self._close_queue(worker.messages)

    def _wait_for_outcome(self, worker: RunningWorker) -> WorkerOutcome:
        while True:
            message = self._next_message(worker)
            if message is not None:
                kind, payload = message
                now = time.monotonic()
                if kind == "runtime":
                    worker.last_runtime_heartbeat = now
                    worker.received_runtime_heartbeat = True
                elif kind == "processor_started":
                    worker.processor_started = True
                    worker.last_progress_heartbeat = now
                elif kind == "progress":
                    worker.last_progress_heartbeat = now
                elif kind == "outcome":
                    return self._finish_reported_outcome(worker, payload)

            now = time.monotonic()
            if worker.cancellation.is_set():
                if worker.cancellation_started_at is None:
                    worker.cancellation_started_at = now
                    self.storage.set_computation_state(
                        worker.job_id,
                        ComputationState.CANCELLING,
                    )
                elif (
                    now - worker.cancellation_started_at
                    >= self.settings.cancellation_grace_seconds
                ):
                    self._terminate(worker, cooperative_grace_seconds=0)
                    return self._record_terminal(
                        worker,
                        ComputationState.CANCELLED,
                        ErrorCode.CANCELLED,
                        "worker did not exit during cancellation grace period",
                    )

            if (
                not worker.received_runtime_heartbeat
                and now - worker.started_at
                > self.settings.worker_startup_timeout_seconds
            ):
                self._terminate(
                    worker,
                    cooperative_grace_seconds=self.settings.cancellation_grace_seconds,
                )
                return self._record_terminal(
                    worker,
                    ComputationState.FAILED,
                    ErrorCode.WORKER_STARTUP_TIMEOUT,
                    "worker did not initialize before the startup deadline",
                )
            if (
                worker.received_runtime_heartbeat
                and now - worker.last_runtime_heartbeat
                > self.settings.runtime_heartbeat_timeout_seconds
            ):
                self._terminate(
                    worker,
                    cooperative_grace_seconds=self.settings.cancellation_grace_seconds,
                )
                return self._record_terminal(
                    worker,
                    ComputationState.FAILED,
                    ErrorCode.WORKER_UNRESPONSIVE,
                    "worker runtime heartbeat timed out",
                )
            if (
                worker.processor_started
                and now - worker.last_progress_heartbeat
                > self.settings.progress_timeout_seconds
            ):
                self._terminate(
                    worker,
                    cooperative_grace_seconds=self.settings.cancellation_grace_seconds,
                )
                return self._record_terminal(
                    worker,
                    ComputationState.FAILED,
                    ErrorCode.PROGRESS_TIMEOUT,
                    "worker progress heartbeat timed out",
                )

            if not worker.process.is_alive():
                worker.process.join()
                late_outcome = self._drain_terminal_outcome(worker)
                if late_outcome is not None:
                    return self._finish_reported_outcome(worker, late_outcome)
                return self._record_terminal(
                    worker,
                    ComputationState.FAILED,
                    ErrorCode.WORKER_CRASHED,
                    f"worker exited unexpectedly with code {worker.process.exitcode}",
                )

    def _next_message(
        self,
        worker: RunningWorker,
        *,
        timeout: float | None = None,
    ) -> tuple[str, Any] | None:
        selected_timeout = (
            self.settings.monitor_interval_seconds if timeout is None else timeout
        )
        try:
            return cast(
                tuple[str, Any],
                worker.messages.get(timeout=selected_timeout),
            )
        except queue.Empty:
            return None

    def _drain_terminal_outcome(
        self,
        worker: RunningWorker,
    ) -> dict[str, Any] | None:
        deadline = time.monotonic() + max(
            0.1,
            self.settings.monitor_interval_seconds * 5,
        )
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            message = self._next_message(worker, timeout=remaining)
            if message is None:
                return None
            kind, payload = message
            now = time.monotonic()
            if kind == "outcome":
                return cast(dict[str, Any], payload)
            if kind == "runtime":
                worker.last_runtime_heartbeat = now
                worker.received_runtime_heartbeat = True
            elif kind == "processor_started":
                worker.processor_started = True
                worker.last_progress_heartbeat = now
            elif kind == "progress":
                worker.last_progress_heartbeat = now

    def _finish_reported_outcome(
        self,
        worker: RunningWorker,
        payload: dict[str, Any],
    ) -> WorkerOutcome:
        if not self._wait_for_reported_exit(worker):
            self._terminate(worker, cooperative_grace_seconds=0)
            return self._record_terminal(
                worker,
                ComputationState.FAILED,
                ErrorCode.WORKER_UNRESPONSIVE,
                "worker reported an outcome but did not exit",
            )
        kind = payload.get("kind")
        if kind == "succeeded":
            try:
                job = self.storage.complete_success(
                    worker.job_id,
                    worker.temporary_result_path,
                    max_array_bytes=self.settings.max_array_bytes,
                    retention_seconds=self.settings.result_retention_seconds,
                )
            except ArrayValidationError as exc:
                worker.temporary_result_path.unlink(missing_ok=True)
                return self._record_terminal(
                    worker,
                    ComputationState.FAILED,
                    ErrorCode.INVALID_RESULT,
                    exc.message,
                )
            except InvalidStateTransition:
                if (
                    self.storage.get_job(worker.job_id).computation_state
                    is ComputationState.CANCELLING
                ):
                    worker.temporary_result_path.unlink(missing_ok=True)
                    return self._record_terminal(
                        worker,
                        ComputationState.CANCELLED,
                        ErrorCode.CANCELLED,
                        "job was cancelled before its result was published",
                    )
                raise
            return self._success_outcome(job)
        worker.temporary_result_path.unlink(missing_ok=True)
        if kind == "cancelled":
            if (
                self.storage.get_job(worker.job_id).computation_state
                is not ComputationState.CANCELLING
            ):
                self.storage.set_computation_state(
                    worker.job_id,
                    ComputationState.CANCELLING,
                )
            return self._record_terminal(
                worker,
                ComputationState.CANCELLED,
                ErrorCode.CANCELLED,
                "job was cancelled",
            )
        if kind == "invalid_result":
            return self._record_terminal(
                worker,
                ComputationState.FAILED,
                ErrorCode.INVALID_RESULT,
                str(payload.get("message", "processor returned an invalid result")),
                local_traceback=payload.get("traceback"),
            )
        return self._record_terminal(
            worker,
            ComputationState.FAILED,
            ErrorCode.WORKER_EXCEPTION,
            str(payload.get("message", "processor failed")),
            local_traceback=payload.get("traceback"),
        )

    def _wait_for_reported_exit(self, worker: RunningWorker) -> bool:
        deadline = (
            time.monotonic() + self.settings.post_outcome_exit_timeout_seconds
        )
        # A multiprocessing queue feeder may keep the child alive until the parent
        # consumes pending heartbeat messages. Drain while allowing normal teardown.
        while worker.process.is_alive():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            self._next_message(
                worker,
                timeout=min(self.settings.monitor_interval_seconds, remaining),
            )
            worker.process.join(timeout=0)
        worker.process.join()
        return True

    def _terminate(
        self,
        worker: RunningWorker,
        *,
        cooperative_grace_seconds: float,
    ) -> None:
        worker.cancellation.set()
        worker.process.join(timeout=cooperative_grace_seconds)
        if worker.process.is_alive():
            worker.process.terminate()
            worker.process.join(timeout=self.settings.termination_grace_seconds)
        if worker.process.is_alive():
            worker.process.kill()
            worker.process.join()
        worker.temporary_result_path.unlink(missing_ok=True)

    def _record_terminal(
        self,
        worker: RunningWorker,
        state: ComputationState,
        code: ErrorCode,
        message: str,
        *,
        local_traceback: str | None = None,
    ) -> WorkerOutcome:
        error = ErrorInfo(code=code, message=message, retryable=False)
        self.storage.set_computation_state(
            worker.job_id,
            state,
            error=error,
            local_traceback=local_traceback,
        )
        return WorkerOutcome(state=state, error=error)

    @staticmethod
    def _success_outcome(job: JobRecord) -> WorkerOutcome:
        return WorkerOutcome(
            state=ComputationState.SUCCEEDED,
            result_path=job.result_path,
            result_size_bytes=job.result_size_bytes,
            result_sha256=job.result_sha256,
        )

    @staticmethod
    def _close_queue(messages: Any) -> None:
        close = getattr(messages, "close", None)
        if close is not None:
            close()
        join_thread = getattr(messages, "join_thread", None)
        if join_thread is not None:
            join_thread()
