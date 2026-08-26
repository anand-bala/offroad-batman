from __future__ import annotations

import asyncio
from pathlib import Path

import httpx
import numpy as np

from offroad_batman.jobs.client import Client
from offroad_batman.jobs.config import ReceiverSettings
from offroad_batman.jobs.models import ComputationState, ResultState
from offroad_batman.jobs.receiver.app import create_receiver_app
from offroad_batman.jobs.receiver.service import ReceiverService


def test_async_client_submits_fetches_verifies_and_acknowledges(
    tmp_path: Path,
) -> None:
    async def run() -> None:
        settings = ReceiverSettings(
            processor="tests.fixtures.processors:double",
            state_directory=tmp_path,
            worker_startup_timeout_seconds=5,
            runtime_heartbeat_timeout_seconds=2,
            progress_timeout_seconds=2,
        )
        service = ReceiverService(settings)
        transport = httpx.ASGITransport(app=create_receiver_app(service))
        async with Client(transport=transport) as client:
            assert client._http.trust_env is False
            job = await client.submit(
                receiver_url="http://olo.mesh:8080",
                array=np.arange(5, dtype=np.float32),
                metadata={"operation": "double"},
                callback_url="http://ragnarhorn.mesh:8080/v1/callbacks",
            )
            await service.wait_for_terminal(job.job_id)
            status = await job.status()
            assert status.computation_state is ComputationState.SUCCEEDED
            result = await job.fetch_and_acknowledge()
            np.testing.assert_array_equal(
                result,
                np.arange(5, dtype=np.float32) * 2,
            )
            acknowledged = await job.status()
            assert acknowledged.result_state is ResultState.ACKNOWLEDGED
        await service.shutdown()

    asyncio.run(run())
