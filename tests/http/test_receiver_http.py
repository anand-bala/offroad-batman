from __future__ import annotations

import asyncio
import json
from pathlib import Path

import httpx
import numpy as np

from offroad_batman.jobs.array_io import decode_array, encode_array
from offroad_batman.jobs.config import ReceiverSettings
from offroad_batman.jobs.models import ComputationState
from offroad_batman.jobs.receiver.app import create_receiver_app
from offroad_batman.jobs.receiver.service import ReceiverService


def _settings(tmp_path: Path, processor: str) -> ReceiverSettings:
    return ReceiverSettings(
        processor=processor,
        state_directory=tmp_path,
        heartbeat_interval_seconds=0.02,
        worker_startup_timeout_seconds=5,
        runtime_heartbeat_timeout_seconds=1,
        progress_timeout_seconds=1,
        cancellation_grace_seconds=0.1,
        termination_grace_seconds=0.1,
        monitor_interval_seconds=0.01,
    )


def _submission(key: str, *, operation: str = "test") -> dict[str, object]:
    return {
        "headers": {"Idempotency-Key": key},
        "data": {
            "metadata": json.dumps({"operation": operation}),
            "callback_url": "http://ragnarhorn.mesh:8080/v1/callbacks",
        },
        "files": {
            "array": (
                "input.npy",
                encode_array(np.arange(4, dtype=np.int16)).data,
                "application/x-npy",
            )
        },
    }


def test_submit_result_fetch_and_idempotent_acknowledgement(tmp_path: Path) -> None:
    async def run() -> None:
        service = ReceiverService(
            _settings(tmp_path, "tests.fixtures.processors:double")
        )
        transport = httpx.ASGITransport(app=create_receiver_app(service))
        async with httpx.AsyncClient(
            transport=transport,
            base_url="http://olo.mesh:8080",
        ) as client:
            response = await client.post("/v1/jobs", **_submission("stable-key"))
            assert response.status_code == 202
            accepted = response.json()
            assert accepted["status_url"].startswith("http://olo.mesh:8080/")

            status = await service.wait_for_terminal(accepted["job_id"])
            assert status.computation_state is ComputationState.SUCCEEDED
            status_response = await client.get(f"/v1/jobs/{accepted['job_id']}")
            assert status_response.json()["result_state"] == "available"

            result = await client.get(f"/v1/jobs/{accepted['job_id']}/result")
            assert result.status_code == 200
            assert result.headers["content-type"] == "application/x-npy"
            assert result.headers["digest"].startswith("sha-256=")
            np.testing.assert_array_equal(
                decode_array(result.content),
                np.arange(4, dtype=np.int16) * 2,
            )

            for _ in range(2):
                acknowledgement = await client.post(
                    f"/v1/jobs/{accepted['job_id']}/result-ack"
                )
                assert acknowledgement.status_code == 200
                assert acknowledgement.json()["result_state"] == "acknowledged"
            unavailable = await client.get(
                f"/v1/jobs/{accepted['job_id']}/result"
            )
            assert unavailable.status_code == 409

            replay = await client.post("/v1/jobs", **_submission("stable-key"))
            assert replay.status_code == 202
            assert replay.json()["job_id"] == accepted["job_id"]
        await service.shutdown()

    asyncio.run(run())


def test_idempotent_replay_precedes_busy_and_cancel_is_async(tmp_path: Path) -> None:
    async def run() -> None:
        service = ReceiverService(
            _settings(tmp_path, "tests.fixtures.processors:cooperative_wait")
        )
        transport = httpx.ASGITransport(app=create_receiver_app(service))
        async with httpx.AsyncClient(
            transport=transport,
            base_url="http://olo.mesh:8080",
        ) as client:
            first = await client.post("/v1/jobs", **_submission("active-key"))
            assert first.status_code == 202
            replay = await client.post("/v1/jobs", **_submission("active-key"))
            assert replay.status_code == 202
            assert replay.json()["job_id"] == first.json()["job_id"]

            busy = await client.post("/v1/jobs", **_submission("other-key"))
            assert busy.status_code == 503
            assert busy.headers["retry-after"] == "5"
            assert busy.json()["error"]["code"] == "receiver_busy"

            cancelled = await client.post(
                f"/v1/jobs/{first.json()['job_id']}/cancel"
            )
            assert cancelled.status_code == 202
            status = await service.wait_for_terminal(first.json()["job_id"])
            assert status.computation_state is ComputationState.CANCELLED
            repeated = await client.post(
                f"/v1/jobs/{first.json()['job_id']}/cancel"
            )
            assert repeated.status_code == 200
        await service.shutdown()

    asyncio.run(run())


def test_submission_errors_are_stable_and_bounded(tmp_path: Path) -> None:
    async def run() -> None:
        service = ReceiverService(
            _settings(tmp_path, "tests.fixtures.processors:double")
        )
        transport = httpx.ASGITransport(app=create_receiver_app(service))
        async with httpx.AsyncClient(
            transport=transport,
            base_url="http://olo.mesh:8080",
        ) as client:
            invalid = _submission("invalid-array")
            invalid["files"] = {
                "array": ("input.npy", b"not-npy", "application/x-npy")
            }
            response = await client.post("/v1/jobs", **invalid)
            assert response.status_code == 422
            assert response.json()["error"]["code"] == "invalid_submission"

            missing = await client.post("/v1/jobs")
            assert missing.status_code == 422
            assert missing.json()["error"]["code"] == "invalid_submission"

            empty_key = _submission(" ")
            response = await client.post("/v1/jobs", **empty_key)
            assert response.status_code == 422
            assert response.json()["error"]["code"] == "invalid_submission"

            oversized = _submission("too-large")
            oversized["files"] = {
                "array": (
                    "input.npy",
                    b"x" * (service.settings.max_request_bytes + 1),
                    "application/x-npy",
                )
            }
            response = await client.post("/v1/jobs", **oversized)
            assert response.status_code == 413
        await service.shutdown()

    asyncio.run(run())
