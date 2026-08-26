"""Receiver business logic shared by HTTP and future foreground commands."""

from __future__ import annotations

import asyncio
import time
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

import httpx
from pydantic import JsonValue

from ..config import ReceiverSettings
from ..errors import ErrorCode, JobsError, ResultExpired, ResultUnavailable
from ..models import (
    ComputationState,
    DeliveryState,
    JobAccepted,
    JobStatus,
    ResultAcknowledgement,
    ResultState,
)
from .delivery import CallbackDispatcher
from .storage import JobRecord, JobStorage
from .supervisor import RunningWorker, WorkerSupervisor


@dataclass(frozen=True)
class ResultArtifact:
    path: Path
    size_bytes: int
    sha256: str


class ReceiverService:
    """Coordinate durable storage with one local worker supervisor."""

    def __init__(
        self,
        settings: ReceiverSettings,
        storage: JobStorage | None = None,
        callback_transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.settings = settings
        if settings.state_directory is None:
            raise ValueError("receiver state_directory was not resolved")
        self.storage = storage or JobStorage(settings.state_directory)
        self.supervisor = WorkerSupervisor(self.storage, settings)
        self.dispatcher = CallbackDispatcher(
            self.storage,
            settings,
            transport=callback_transport,
        )
        # One Uvicorn worker owns the only active child and its wait task.
        self._workers: dict[str, RunningWorker] = {}
        self._tasks: dict[str, asyncio.Task[object]] = {}
        self._cleanup_task: asyncio.Task[None] | None = None
        self._accepted_job_id: str | None = None
        self._job_accepted = asyncio.Event()

    async def start(self) -> None:
        """Run startup cleanup and start receiver-owned background tasks."""

        if self._cleanup_task is not None:
            return
        await asyncio.to_thread(
            self.storage.reconcile_interrupted_jobs,
            advertised_url=self.settings.advertised_url,
            callback_delivery_lifetime_seconds=(
                self.settings.callback_delivery_lifetime_seconds
            ),
        )
        await asyncio.to_thread(
            self.storage.cleanup,
            diagnostic_retention_seconds=self.settings.diagnostic_retention_seconds,
        )
        await asyncio.to_thread(self.storage.cleanup_temporary_files)
        self.dispatcher.start()
        self.dispatcher.wake()
        self._cleanup_task = asyncio.create_task(self._cleanup_loop())

    def submit(
        self,
        *,
        idempotency_key: str,
        metadata: Mapping[str, JsonValue],
        callback_url: str,
        input_data: bytes,
    ) -> JobAccepted:
        admission = self.storage.admit(
            idempotency_key=idempotency_key,
            metadata=metadata,
            callback_url=callback_url,
            input_data=input_data,
            max_array_bytes=self.settings.max_array_bytes,
        )
        job = admission.job
        if not admission.replayed:
            self._accepted_job_id = job.job_id
            self._job_accepted.set()
            worker = self.supervisor.start(job.job_id)
            self._workers[job.job_id] = worker
            task = asyncio.create_task(self._finish_worker(worker))
            self._tasks[job.job_id] = task
            def worker_finished(completed: asyncio.Task[object]) -> None:
                self._worker_finished(job.job_id, completed)

            task.add_done_callback(worker_finished)
        return JobAccepted.model_validate(
            {
                "job_id": job.job_id,
                "status_url": (
                    f"{self.settings.advertised_url.rstrip('/')}/v1/jobs/"
                    f"{job.job_id}"
                ),
            }
        )

    def status(self, job_id: str) -> JobStatus:
        return self._status_from_record(self.storage.get_job(job_id))

    def cancel(self, job_id: str) -> tuple[JobStatus, bool]:
        job = self.storage.get_job(job_id)
        if job.computation_state in {
            ComputationState.SUCCEEDED,
            ComputationState.FAILED,
        }:
            raise JobsError(
                code=ErrorCode.INVALID_SUBMISSION,
                message="terminal job cannot be cancelled",
                retryable=False,
            )
        if job.computation_state in {
            ComputationState.CANCELLING,
            ComputationState.CANCELLED,
        }:
            return self._status_from_record(job), False
        job = self.storage.set_computation_state(
            job_id,
            ComputationState.CANCELLING,
        )
        worker = self._workers.get(job_id)
        if worker is not None:
            worker.cancel()
        return self._status_from_record(job), True

    def result(self, job_id: str) -> ResultArtifact:
        job = self.storage.get_job(job_id)
        if job.result_state is ResultState.EXPIRED:
            raise ResultExpired()
        if (
            job.result_state is ResultState.AVAILABLE
            and job.result_expires_at is not None
            and job.result_expires_at <= time.time()
        ):
            self.storage.expire_result(job_id)
            raise ResultExpired()
        if (
            job.result_state is not ResultState.AVAILABLE
            or job.result_path is None
            or job.result_size_bytes is None
            or job.result_sha256 is None
            or not job.result_path.is_file()
        ):
            raise ResultUnavailable()
        return ResultArtifact(
            path=job.result_path,
            size_bytes=job.result_size_bytes,
            sha256=job.result_sha256,
        )

    def acknowledge_result(self, job_id: str) -> ResultAcknowledgement:
        job = self.storage.acknowledge_result(job_id)
        return ResultAcknowledgement(job_id=job.job_id)

    async def wait_for_terminal(
        self,
        job_id: str,
        *,
        timeout: float = 30,
    ) -> JobStatus:
        task = self._tasks.get(job_id)
        if task is not None:
            await asyncio.wait_for(asyncio.shield(task), timeout=timeout)
        return self.status(job_id)

    async def wait_until_once_complete(self) -> None:
        """Wait for the one-shot receiver's accepted job lifecycle to settle."""

        await self._job_accepted.wait()
        if self._accepted_job_id is None:
            return
        while True:
            job = self.storage.get_job(self._accepted_job_id)
            if job.computation_state is ComputationState.SUCCEEDED:
                if job.result_state in {
                    ResultState.ACKNOWLEDGED,
                    ResultState.EXPIRED,
                }:
                    return
            elif job.computation_state in {
                ComputationState.FAILED,
                ComputationState.CANCELLED,
            } and job.delivery_state in {
                DeliveryState.ACKNOWLEDGED,
                DeliveryState.ABANDONED,
            }:
                return
            await asyncio.sleep(self.settings.monitor_interval_seconds)

    async def shutdown(self) -> None:
        workers = tuple(self._workers.values())
        for worker in workers:
            worker.cancel()
        tasks = tuple(self._tasks.values())
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if self._cleanup_task is not None:
            self._cleanup_task.cancel()
            await asyncio.gather(self._cleanup_task, return_exceptions=True)
            self._cleanup_task = None
        await self.dispatcher.stop()

    async def _finish_worker(self, worker: RunningWorker) -> object:
        outcome = await asyncio.to_thread(self.supervisor.wait, worker)
        await asyncio.to_thread(
            self.storage.ensure_terminal_callback,
            worker.job_id,
            advertised_url=self.settings.advertised_url,
            delivery_lifetime_seconds=(
                self.settings.callback_delivery_lifetime_seconds
            ),
        )
        self.dispatcher.wake()
        return outcome

    async def _cleanup_loop(self) -> None:
        while True:
            await asyncio.sleep(self.settings.cleanup_interval_seconds)
            await asyncio.to_thread(
                self.storage.cleanup,
                diagnostic_retention_seconds=(
                    self.settings.diagnostic_retention_seconds
                ),
            )

    def _worker_finished(self, job_id: str, task: asyncio.Task[object]) -> None:
        self._workers.pop(job_id, None)
        self._tasks.pop(job_id, None)
        if not task.cancelled():
            task.exception()

    @staticmethod
    def _status_from_record(job: JobRecord) -> JobStatus:
        return JobStatus(
            job_id=job.job_id,
            computation_state=job.computation_state,
            delivery_state=job.delivery_state,
            result_state=job.result_state,
            error=job.error,
        )
