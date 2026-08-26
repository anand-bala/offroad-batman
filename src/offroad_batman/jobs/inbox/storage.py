"""Durable terminal-event deduplication and waiting."""

from __future__ import annotations

import asyncio
import json
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from pydantic import TypeAdapter

from ..errors import IdempotencyConflict
from ..models import TerminalEvent

_TERMINAL_EVENT_ADAPTER: TypeAdapter[TerminalEvent] = TypeAdapter(TerminalEvent)


@dataclass(frozen=True)
class InboxEvent:
    event_id: str
    job_id: str
    payload: dict[str, Any]
    received_at: float


class InboxStorage:
    """Store one immutable payload for each callback event ID."""

    def __init__(self, state_directory: Path) -> None:
        self.state_directory = Path(state_directory)
        self.state_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.database_path = self.state_directory / "inbox.sqlite3"
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS events (
                    event_id TEXT PRIMARY KEY,
                    job_id TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    received_at REAL NOT NULL
                )
                """
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS events_by_job ON events(job_id)"
            )

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA synchronous = FULL")
        return connection

    def record(self, payload: dict[str, Any]) -> tuple[InboxEvent, bool]:
        event = _TERMINAL_EVENT_ADAPTER.validate_python(payload)
        canonical = json.dumps(
            event.model_dump(mode="json"),
            separators=(",", ":"),
            sort_keys=True,
        )
        received_at = time.time()
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                "SELECT * FROM events WHERE event_id = ?",
                (event.event_id,),
            ).fetchone()
            if existing is not None:
                if existing["payload_json"] != canonical:
                    raise IdempotencyConflict()
                return self._row_to_event(existing), True
            connection.execute(
                "INSERT INTO events (event_id, job_id, payload_json, received_at) "
                "VALUES (?, ?, ?, ?)",
                (event.event_id, event.job_id, canonical, received_at),
            )
        stored = self.get_event(event.event_id)
        if stored is None:
            raise RuntimeError("callback event was not stored")
        return stored, False

    def get_event(self, event_id: str) -> InboxEvent | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM events WHERE event_id = ?",
                (event_id,),
            ).fetchone()
        return self._row_to_event(row) if row is not None else None

    def get_for_job(self, job_id: str) -> InboxEvent | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM events WHERE job_id = ? "
                "ORDER BY received_at LIMIT 1",
                (job_id,),
            ).fetchone()
        return self._row_to_event(row) if row is not None else None

    @staticmethod
    def _row_to_event(row: sqlite3.Row) -> InboxEvent:
        return InboxEvent(
            event_id=row["event_id"],
            job_id=row["job_id"],
            payload=json.loads(row["payload_json"]),
            received_at=row["received_at"],
        )


class CallbackInbox:
    """Persist callbacks and let the foreground sender await a job event."""

    def __init__(self, state_directory: Path) -> None:
        self.storage = InboxStorage(state_directory)
        self._received = asyncio.Event()

    async def accept(self, payload: dict[str, Any]) -> tuple[InboxEvent, bool]:
        stored, duplicate = await asyncio.to_thread(self.storage.record, payload)
        self._received.set()
        return stored, duplicate

    def lookup_event(self, event_id: str) -> InboxEvent | None:
        return self.storage.get_event(event_id)

    def lookup_job(self, job_id: str) -> InboxEvent | None:
        return self.storage.get_for_job(job_id)

    async def wait_for_job(self, job_id: str, *, timeout: float) -> InboxEvent:
        """Wait for a durable event, checking storage before every sleep."""

        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            # Clear first so an arrival between lookup and wait cannot be lost.
            self._received.clear()
            stored = await asyncio.to_thread(self.storage.get_for_job, job_id)
            if stored is not None:
                return stored
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise asyncio.TimeoutError
            await asyncio.wait_for(self._received.wait(), timeout=remaining)
