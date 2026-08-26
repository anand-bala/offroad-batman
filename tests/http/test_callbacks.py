from __future__ import annotations

import asyncio
from pathlib import Path

import httpx
import numpy as np

from offroad_batman.jobs.array_io import encode_array
from offroad_batman.jobs.config import ReceiverSettings
from offroad_batman.jobs.inbox import CallbackInbox, create_callback_inbox_app
from offroad_batman.jobs.models import (
    ComputationState,
    DeliveryState,
    ResultState,
)
from offroad_batman.jobs.receiver.service import ReceiverService


def _settings(tmp_path: Path, **overrides: object) -> ReceiverSettings:
    values: dict[str, object] = {
        "processor": "tests.fixtures.processors:double",
        "state_directory": tmp_path,
        "heartbeat_interval_seconds": 0.02,
        "worker_startup_timeout_seconds": 5,
        "runtime_heartbeat_timeout_seconds": 1,
        "progress_timeout_seconds": 1,
        "cancellation_grace_seconds": 0.1,
        "termination_grace_seconds": 0.1,
        "post_outcome_exit_timeout_seconds": 1,
        "monitor_interval_seconds": 0.01,
        "callback_initial_backoff_seconds": 0.01,
        "callback_max_backoff_seconds": 0.02,
        "cleanup_interval_seconds": 0.01,
    }
    values.update(overrides)
    return ReceiverSettings(**values)


def _submit(service: ReceiverService, key: str):
    return service.submit(
        idempotency_key=key,
        metadata={"operation": "double"},
        callback_url="http://ragnarhorn.mesh:8080/v1/callbacks",
        input_data=encode_array(np.arange(4, dtype=np.int16)).data,
    )


async def _wait_for_delivery(
    service: ReceiverService,
    job_id: str,
    target: DeliveryState,
    timeout: float = 3,
) -> None:
    deadline = asyncio.get_running_loop().time() + timeout
    while service.status(job_id).delivery_state is not target:
        if asyncio.get_running_loop().time() >= deadline:
            raise AssertionError(f"delivery did not reach {target.value}")
        await asyncio.sleep(0.01)


def test_success_callback_retries_with_stable_payload_and_event_id(
    tmp_path: Path,
) -> None:
    async def run() -> None:
        payloads: list[dict[str, object]] = []

        async def callback(request: httpx.Request) -> httpx.Response:
            import json

            payloads.append(json.loads(request.content))
            status = 503 if len(payloads) == 1 else 204
            return httpx.Response(status)

        service = ReceiverService(
            _settings(tmp_path),
            callback_transport=httpx.MockTransport(callback),
        )
        await service.start()
        accepted = _submit(service, "callback-retry")
        status = await service.wait_for_terminal(accepted.job_id)
        assert status.computation_state is ComputationState.SUCCEEDED
        await _wait_for_delivery(
            service,
            accepted.job_id,
            DeliveryState.ACKNOWLEDGED,
        )

        callback = service.storage.get_callback(accepted.job_id)
        assert callback.attempt_count == 1
        assert len(payloads) == 2
        assert payloads[0] == payloads[1]
        assert payloads[0]["event_id"] == callback.event_id
        assert payloads[0]["state"] == "succeeded"
        assert payloads[0]["result_url"].startswith("http://olo.mesh:8080/")
        assert payloads[0]["result_ack_url"].endswith("/result-ack")
        assert payloads[0]["size_bytes"] > 0
        assert len(payloads[0]["sha256"]) == 64
        await service.shutdown()

    asyncio.run(run())


def test_delivery_does_not_hold_computation_slot(tmp_path: Path) -> None:
    async def run() -> None:
        async def unavailable(request: httpx.Request) -> httpx.Response:
            del request
            return httpx.Response(503)

        service = ReceiverService(
            _settings(tmp_path),
            callback_transport=httpx.MockTransport(unavailable),
        )
        await service.start()
        first = _submit(service, "first")
        await service.wait_for_terminal(first.job_id)
        await _wait_for_delivery(service, first.job_id, DeliveryState.RETRYING)

        second = _submit(service, "second")
        assert second.job_id != first.job_id
        second_status = await service.wait_for_terminal(second.job_id)
        assert second_status.computation_state is ComputationState.SUCCEEDED
        await service.shutdown()

    asyncio.run(run())


def test_failed_callback_contains_structured_error(tmp_path: Path) -> None:
    async def run() -> None:
        payloads: list[dict[str, object]] = []

        async def callback(request: httpx.Request) -> httpx.Response:
            import json

            payloads.append(json.loads(request.content))
            return httpx.Response(200)

        service = ReceiverService(
            _settings(
                tmp_path,
                processor="tests.fixtures.processors:fail",
            ),
            callback_transport=httpx.MockTransport(callback),
        )
        await service.start()
        accepted = _submit(service, "failure")
        status = await service.wait_for_terminal(accepted.job_id)
        assert status.computation_state is ComputationState.FAILED
        await _wait_for_delivery(
            service,
            accepted.job_id,
            DeliveryState.ACKNOWLEDGED,
        )
        assert payloads[0]["state"] == "failed"
        assert payloads[0]["error"]["code"] == "worker_exception"
        assert "traceback" not in payloads[0]["error"]
        await service.shutdown()

    asyncio.run(run())


def test_cleanup_expires_result_and_callback_independently(tmp_path: Path) -> None:
    async def run() -> None:
        async def unavailable(request: httpx.Request) -> httpx.Response:
            del request
            return httpx.Response(503)

        service = ReceiverService(
            _settings(
                tmp_path,
                result_retention_seconds=0.03,
                callback_delivery_lifetime_seconds=0.08,
            ),
            callback_transport=httpx.MockTransport(unavailable),
        )
        await service.start()
        accepted = _submit(service, "expiration")
        await service.wait_for_terminal(accepted.job_id)
        await _wait_for_delivery(
            service,
            accepted.job_id,
            DeliveryState.ABANDONED,
        )
        deadline = asyncio.get_running_loop().time() + 2
        while service.status(accepted.job_id).result_state is not ResultState.EXPIRED:
            if asyncio.get_running_loop().time() >= deadline:
                raise AssertionError("result did not expire")
            await asyncio.sleep(0.01)
        job = service.storage.get_job(accepted.job_id)
        assert job.result_path is not None
        assert job.result_path.exists() is False
        await service.shutdown()

    asyncio.run(run())


def test_callback_inbox_deduplicates_durably_and_wakes_waiter(
    tmp_path: Path,
) -> None:
    async def run() -> None:
        inbox = CallbackInbox(tmp_path)
        transport = httpx.ASGITransport(app=create_callback_inbox_app(inbox))
        payload = {
            "event_id": "event-one",
            "job_id": "job-one",
            "state": "failed",
            "error": {
                "code": "worker_exception",
                "message": "failed",
                "retryable": False,
            },
        }
        waiter = asyncio.create_task(inbox.wait_for_job("job-one", timeout=2))
        async with httpx.AsyncClient(
            transport=transport,
            base_url="http://ragnarhorn.mesh:8080",
        ) as client:
            first = await client.post("/v1/callbacks", json=payload)
            second = await client.post("/v1/callbacks", json=payload)
            assert first.status_code == 200
            assert first.json()["duplicate"] is False
            assert second.status_code == 200
            assert second.json()["duplicate"] is True

            conflicting = dict(payload)
            conflicting["job_id"] = "another-job"
            conflict = await client.post("/v1/callbacks", json=conflicting)
            assert conflict.status_code == 409
        event = await waiter
        assert event.event_id == "event-one"
        reopened = CallbackInbox(tmp_path)
        assert reopened.lookup_job("job-one") is not None

    asyncio.run(run())


def test_startup_removes_orphan_temps_before_workers_start(tmp_path: Path) -> None:
    async def run() -> None:
        orphan_directory = tmp_path / "jobs" / "orphan"
        orphan_directory.mkdir(parents=True)
        hidden_temporary = orphan_directory / ".input.npy.crash.tmp"
        worker_temporary = orphan_directory / "result.npy.worker.tmp"
        hidden_temporary.write_bytes(b"partial")
        worker_temporary.write_bytes(b"partial")
        service = ReceiverService(_settings(tmp_path))

        await service.start()

        assert hidden_temporary.exists() is False
        assert worker_temporary.exists() is False
        await service.shutdown()

    asyncio.run(run())
