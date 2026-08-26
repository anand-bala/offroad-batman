"""Persistent terminal callback delivery for one foreground receiver."""

from __future__ import annotations

import asyncio
import random
import time

import httpx

from ..config import ReceiverSettings
from .storage import CallbackRecord, JobStorage

CALLBACK_TIMEOUT = httpx.Timeout(connect=5, read=120, write=120, pool=5)


class CallbackDispatcher:
    """Deliver the single terminal callback associated with each completed job."""

    def __init__(
        self,
        storage: JobStorage,
        settings: ReceiverSettings,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.storage = storage
        self.settings = settings
        self._transport = transport
        self._wake = asyncio.Event()
        self._stopping = False
        self._task: asyncio.Task[None] | None = None
        self._http: httpx.AsyncClient | None = None

    def start(self) -> None:
        """Start delivery inside the current foreground event loop."""

        if self._task is not None:
            return
        self._http = httpx.AsyncClient(
            timeout=CALLBACK_TIMEOUT,
            transport=self._transport,
            trust_env=False,
            follow_redirects=False,
        )
        self._task = asyncio.create_task(self._run())

    def wake(self) -> None:
        """Notify the dispatcher that new persistent work may be due."""

        self._wake.set()

    async def stop(self) -> None:
        if self._task is None:
            return
        self._stopping = True
        self._wake.set()
        await self._task
        self._task = None
        if self._http is not None:
            await self._http.aclose()
            self._http = None

    async def _run(self) -> None:
        while not self._stopping:
            callback = await asyncio.to_thread(self.storage.next_due_callback)
            if callback is None:
                self._wake.clear()
                try:
                    await asyncio.wait_for(self._wake.wait(), timeout=0.25)
                except asyncio.TimeoutError:
                    pass
                continue
            await self._deliver(callback)

    async def _deliver(self, callback: CallbackRecord) -> None:
        if callback.expires_at <= time.time():
            await asyncio.to_thread(
                self.storage.mark_callback_abandoned,
                callback.job_id,
                error="callback delivery lifetime expired",
            )
            return
        if self._http is None:
            return
        try:
            response = await self._http.post(
                callback.callback_url,
                json=callback.payload,
            )
        except (httpx.TimeoutException, httpx.NetworkError) as exc:
            await self._retry(callback, str(exc) or type(exc).__name__)
            return
        if 200 <= response.status_code < 300:
            await asyncio.to_thread(
                self.storage.mark_callback_acknowledged,
                callback.job_id,
            )
        elif response.status_code in {408, 425, 429} or response.status_code >= 500:
            await self._retry(callback, f"HTTP {response.status_code}")
        else:
            await asyncio.to_thread(
                self.storage.mark_callback_abandoned,
                callback.job_id,
                error=f"callback rejected with HTTP {response.status_code}",
            )

    async def _retry(self, callback: CallbackRecord, error: str) -> None:
        delay = min(
            self.settings.callback_initial_backoff_seconds
            * (2**callback.attempt_count),
            self.settings.callback_max_backoff_seconds,
        )
        # Jitter prevents olo and a restarted peer from settling into synchronized
        # retries after the mesh reconnects.
        delay *= 0.75 + random.random() * 0.5
        next_attempt = time.time() + delay
        if next_attempt >= callback.expires_at:
            await asyncio.to_thread(
                self.storage.mark_callback_abandoned,
                callback.job_id,
                error="callback delivery lifetime expired",
            )
        else:
            await asyncio.to_thread(
                self.storage.mark_callback_retry,
                callback.job_id,
                next_attempt_at=next_attempt,
                error=error,
            )
