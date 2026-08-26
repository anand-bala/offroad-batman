from __future__ import annotations

import asyncio
from pathlib import Path

import httpx
import numpy as np

from offroad_batman.jobs.array_io import encode_array
from offroad_batman.jobs.config import ReceiverSettings
from offroad_batman.jobs.errors import ErrorCode
from offroad_batman.jobs.models import ComputationState, DeliveryState
from offroad_batman.jobs.receiver.service import ReceiverService
from offroad_batman.jobs.receiver.storage import JobStorage


def test_restart_fails_interrupted_job_releases_slot_and_resumes_callback(
    tmp_path: Path,
) -> None:
    async def run() -> None:
        storage = JobStorage(tmp_path)
        admitted = storage.admit(
            idempotency_key="interrupted-key",
            metadata={"operation": "test"},
            callback_url="http://ragnarhorn.mesh:8080/v1/callbacks",
            input_data=encode_array(np.arange(4)).data,
            max_array_bytes=4096,
            job_id="interrupted-job",
        )
        storage.set_computation_state(
            admitted.job.job_id,
            ComputationState.RUNNING,
        )
        delivered: list[dict[str, object]] = []

        async def callback(request: httpx.Request) -> httpx.Response:
            import json

            delivered.append(json.loads(request.content))
            return httpx.Response(200)

        settings = ReceiverSettings(
            state_directory=tmp_path,
            callback_initial_backoff_seconds=0.01,
            callback_max_backoff_seconds=0.02,
            cleanup_interval_seconds=0.05,
        )
        service = ReceiverService(
            settings,
            callback_transport=httpx.MockTransport(callback),
        )
        await service.start()

        deadline = asyncio.get_running_loop().time() + 2
        while (
            service.status(admitted.job.job_id).delivery_state
            is not DeliveryState.ACKNOWLEDGED
        ):
            if asyncio.get_running_loop().time() >= deadline:
                raise AssertionError("restart callback was not delivered")
            await asyncio.sleep(0.01)
        recovered = service.storage.get_job(admitted.job.job_id)
        assert recovered.computation_state is ComputationState.FAILED
        assert recovered.error is not None
        assert recovered.error.code is ErrorCode.RECEIVER_RESTARTED
        assert delivered[0]["state"] == "failed"
        assert delivered[0]["error"]["code"] == "receiver_restarted"

        replacement = service.storage.admit(
            idempotency_key="replacement-key",
            metadata={},
            callback_url="http://ragnarhorn.mesh:8080/v1/callbacks",
            input_data=encode_array(np.arange(2)).data,
            max_array_bytes=4096,
            job_id="replacement-job",
        )
        assert replacement.job.computation_state is ComputationState.ACCEPTED
        await service.shutdown()

    asyncio.run(run())


def test_restart_preserves_unexpired_terminal_result(tmp_path: Path) -> None:
    async def run() -> None:
        settings = ReceiverSettings(
            processor="tests.fixtures.processors:double",
            state_directory=tmp_path,
            worker_startup_timeout_seconds=5,
            runtime_heartbeat_timeout_seconds=2,
            progress_timeout_seconds=2,
        )
        first = ReceiverService(settings)
        accepted = first.submit(
            idempotency_key="success-key",
            metadata={},
            callback_url="http://ragnarhorn.mesh:8080/v1/callbacks",
            input_data=encode_array(np.arange(3)).data,
        )
        await first.wait_for_terminal(accepted.job_id)
        original = first.storage.get_job(accepted.job_id)
        assert original.result_path is not None
        assert original.result_path.exists()
        await first.shutdown()

        restarted = ReceiverService(
            settings,
            callback_transport=httpx.MockTransport(
                lambda request: httpx.Response(200)
            ),
        )
        await restarted.start()
        preserved = restarted.storage.get_job(accepted.job_id)
        assert preserved.computation_state is ComputationState.SUCCEEDED
        assert preserved.result_path == original.result_path
        assert preserved.result_path is not None
        assert preserved.result_path.exists()
        await restarted.shutdown()

    asyncio.run(run())
