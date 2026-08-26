"""Async sender client for MANET NumPy jobs."""

from __future__ import annotations

import json
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

import httpx
import numpy.typing as npt
from pydantic import JsonValue

from .array_io import decode_array, encode_array, verify_payload
from .models import JobAccepted, JobStatus, ResultAcknowledgement

DEFAULT_HTTP_TIMEOUT = httpx.Timeout(connect=5, read=120, write=120, pool=5)


class Client:
    """Async HTTP client using libc resolution and no ambient proxy settings."""

    def __init__(
        self,
        *,
        timeout: httpx.Timeout = DEFAULT_HTTP_TIMEOUT,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._http = httpx.AsyncClient(
            timeout=timeout,
            transport=transport,
            trust_env=False,
            follow_redirects=False,
        )

    async def __aenter__(self) -> Client:
        return self

    async def __aexit__(self, *args: object) -> None:
        await self.close()

    async def close(self) -> None:
        await self._http.aclose()

    async def submit(
        self,
        *,
        receiver_url: str,
        array: npt.NDArray[Any],
        metadata: Mapping[str, JsonValue],
        callback_url: str,
        idempotency_key: str | None = None,
    ) -> RemoteJob:
        encoded = encode_array(array)
        selected_key = idempotency_key or str(uuid.uuid4())
        response = await self._http.post(
            f"{receiver_url.rstrip('/')}/v1/jobs",
            headers={"Idempotency-Key": selected_key},
            data={
                "metadata": json.dumps(metadata, allow_nan=False),
                "callback_url": callback_url,
            },
            files={
                "array": ("input.npy", encoded.data, "application/x-npy"),
            },
        )
        response.raise_for_status()
        accepted = JobAccepted.model_validate(response.json())
        return RemoteJob(
            client=self,
            job_id=accepted.job_id,
            status_url=str(accepted.status_url),
            idempotency_key=selected_key,
        )


@dataclass(frozen=True)
class RemoteJob:
    client: Client
    job_id: str
    status_url: str
    idempotency_key: str

    async def status(self) -> JobStatus:
        response = await self.client._http.get(self.status_url)
        response.raise_for_status()
        return JobStatus.model_validate(response.json())

    async def cancel(self) -> JobStatus:
        response = await self.client._http.post(f"{self.status_url}/cancel")
        response.raise_for_status()
        return JobStatus.model_validate(response.json())

    async def fetch_result(
        self,
        *,
        expected_size_bytes: int | None = None,
        expected_sha256: str | None = None,
    ) -> npt.NDArray[Any]:
        """Download and verify a result before returning its decoded array."""

        response = await self.client._http.get(f"{self.status_url}/result")
        response.raise_for_status()
        digest = response.headers.get("X-Content-SHA256")
        if digest is None:
            raise ValueError("result response did not include a SHA-256 digest")
        advertised_size = int(response.headers["Content-Length"])
        if expected_size_bytes is not None and advertised_size != expected_size_bytes:
            raise ValueError("result size differs from the terminal callback")
        if expected_sha256 is not None and digest.lower() != expected_sha256.lower():
            raise ValueError("result digest differs from the terminal callback")
        verify_payload(
            response.content,
            size_bytes=advertised_size,
            sha256=digest,
        )
        return decode_array(response.content)

    async def acknowledge_result(self) -> ResultAcknowledgement:
        response = await self.client._http.post(f"{self.status_url}/result-ack")
        response.raise_for_status()
        return ResultAcknowledgement.model_validate(response.json())

    async def fetch_and_acknowledge(
        self,
        *,
        expected_size_bytes: int | None = None,
        expected_sha256: str | None = None,
    ) -> npt.NDArray[Any]:
        result = await self.fetch_result(
            expected_size_bytes=expected_size_bytes,
            expected_sha256=expected_sha256,
        )
        await self.acknowledge_result()
        return result
