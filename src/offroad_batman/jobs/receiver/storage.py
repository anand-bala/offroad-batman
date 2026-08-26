"""SQLite persistence and atomic single-slot job admission."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sqlite3
import time
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from pydantic import JsonValue

from ..array_io import decode_array
from ..errors import (
    ErrorCode,
    IdempotencyConflict,
    ReceiverBusy,
    ResultExpired,
    ResultUnavailable,
    UnknownJob,
)
from ..models import (
    CancelledEvent,
    ComputationState,
    DeliveryState,
    ErrorInfo,
    FailedEvent,
    ResultState,
    SuccessEvent,
    require_state_transition,
)

SCHEMA_VERSION = 2
_SAFE_JOB_ID = re.compile(r"^[A-Za-z0-9_-]+$")

_SCHEMA = """
CREATE TABLE jobs (
    job_id TEXT PRIMARY KEY,
    idempotency_key TEXT NOT NULL UNIQUE,
    request_fingerprint TEXT NOT NULL,
    metadata_json TEXT NOT NULL,
    callback_url TEXT NOT NULL,
    computation_state TEXT NOT NULL,
    delivery_state TEXT NOT NULL,
    result_state TEXT NOT NULL,
    error_code TEXT,
    error_message TEXT,
    error_retryable INTEGER,
    local_traceback TEXT,
    input_path TEXT NOT NULL,
    input_size_bytes INTEGER NOT NULL,
    input_sha256 TEXT NOT NULL,
    result_path TEXT,
    result_size_bytes INTEGER,
    result_sha256 TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    result_expires_at REAL,
    callback_attempt_count INTEGER NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX one_active_job
ON jobs ((1))
WHERE computation_state IN ('accepted', 'running', 'cancelling');
"""

_CALLBACK_SCHEMA = """
CREATE TABLE terminal_callbacks (
    job_id TEXT PRIMARY KEY REFERENCES jobs(job_id) ON DELETE CASCADE,
    event_id TEXT NOT NULL UNIQUE,
    callback_url TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    delivery_state TEXT NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at REAL NOT NULL,
    expires_at REAL NOT NULL,
    last_error TEXT
);
"""


@dataclass(frozen=True)
class JobRecord:
    job_id: str
    idempotency_key: str
    request_fingerprint: str
    metadata: dict[str, Any]
    callback_url: str
    computation_state: ComputationState
    delivery_state: DeliveryState
    result_state: ResultState
    error: ErrorInfo | None
    local_traceback: str | None
    input_path: Path
    input_size_bytes: int
    input_sha256: str
    result_path: Path | None
    result_size_bytes: int | None
    result_sha256: str | None
    created_at: float
    updated_at: float
    result_expires_at: float | None


@dataclass(frozen=True)
class AdmissionResult:
    job: JobRecord
    replayed: bool


@dataclass(frozen=True)
class CallbackRecord:
    job_id: str
    event_id: str
    callback_url: str
    payload: dict[str, Any]
    delivery_state: DeliveryState
    attempt_count: int
    next_attempt_at: float
    expires_at: float
    last_error: str | None


def request_fingerprint(
    metadata: Mapping[str, JsonValue],
    callback_url: str,
    input_sha256: str,
) -> str:
    """Build a stable fingerprint for idempotency conflict detection."""

    canonical = json.dumps(
        {
            "callback_url": callback_url,
            "input_sha256": input_sha256,
            "metadata": metadata,
        },
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


class JobStorage:
    """Own the receiver's SQLite database and durable array directory."""

    def __init__(self, state_directory: Path) -> None:
        self.state_directory = Path(state_directory)
        self.database_path = self.state_directory / "jobs.sqlite3"
        self.jobs_directory = self.state_directory / "jobs"
        self.state_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.jobs_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        # One foreground receiver owns this database. FULL synchronization keeps
        # accepted inputs durable without WAL's multi-process setup complexity.
        connection.execute("PRAGMA synchronous = FULL")
        return connection

    def _initialize(self) -> None:
        with self._connect() as connection:
            version = connection.execute("PRAGMA user_version").fetchone()[0]
            if version == 0:
                connection.executescript(_SCHEMA)
                connection.executescript(_CALLBACK_SCHEMA)
                connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
            elif version == 1:
                connection.executescript(_CALLBACK_SCHEMA)
                connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
            elif version != SCHEMA_VERSION:
                raise RuntimeError(f"unsupported jobs schema version: {version}")

    def admit(
        self,
        *,
        idempotency_key: str,
        metadata: Mapping[str, JsonValue],
        callback_url: str,
        input_data: bytes,
        max_array_bytes: int,
        job_id: str | None = None,
        retry_after_seconds: int = 5,
    ) -> AdmissionResult:
        """Durably admit one job, checking idempotency before slot occupancy."""

        if not idempotency_key:
            raise ValueError("idempotency_key must not be empty")
        input_sha256 = hashlib.sha256(input_data).hexdigest()
        fingerprint = request_fingerprint(metadata, callback_url, input_sha256)
        selected_job_id = job_id or uuid.uuid4().hex
        self._validate_job_id(selected_job_id)
        now = time.time()
        job_directory = self.jobs_directory / selected_job_id
        input_path = job_directory / "input.npy"

        connection = self._connect()
        wrote_input = False
        try:
            # Idempotency lookup and slot reservation share one write transaction,
            # so a replay wins over the busy response and two callers cannot enter.
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                "SELECT * FROM jobs WHERE idempotency_key = ?",
                (idempotency_key,),
            ).fetchone()
            if existing is not None:
                if existing["request_fingerprint"] != fingerprint:
                    raise IdempotencyConflict()
                connection.commit()
                return AdmissionResult(self._row_to_job(existing), replayed=True)

            decode_array(input_data, max_size_bytes=max_array_bytes)
            active = connection.execute(
                "SELECT 1 FROM jobs "
                "WHERE computation_state IN ('accepted', 'running', 'cancelling') "
                "LIMIT 1"
            ).fetchone()
            if active is not None:
                raise ReceiverBusy(retry_after_seconds)

            job_directory.mkdir(mode=0o700)
            self._write_atomic(input_path, input_data)
            wrote_input = True
            metadata_json = json.dumps(
                metadata,
                allow_nan=False,
                separators=(",", ":"),
                sort_keys=True,
            )
            connection.execute(
                """
                INSERT INTO jobs (
                    job_id, idempotency_key, request_fingerprint, metadata_json,
                    callback_url, computation_state, delivery_state, result_state,
                    input_path, input_size_bytes, input_sha256, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    selected_job_id,
                    idempotency_key,
                    fingerprint,
                    metadata_json,
                    callback_url,
                    ComputationState.ACCEPTED.value,
                    DeliveryState.PENDING.value,
                    ResultState.UNAVAILABLE.value,
                    str(input_path),
                    len(input_data),
                    input_sha256,
                    now,
                    now,
                ),
            )
            connection.commit()
        except BaseException:
            connection.rollback()
            if wrote_input:
                input_path.unlink(missing_ok=True)
                try:
                    job_directory.rmdir()
                except OSError:
                    pass
            raise
        finally:
            connection.close()
        return AdmissionResult(self.get_job(selected_job_id), replayed=False)

    def get_job(self, job_id: str) -> JobRecord:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM jobs WHERE job_id = ?", (job_id,)
            ).fetchone()
        if row is None:
            raise UnknownJob(job_id)
        return self._row_to_job(row)

    def set_computation_state(
        self,
        job_id: str,
        target: ComputationState,
        *,
        error: ErrorInfo | None = None,
        local_traceback: str | None = None,
    ) -> JobRecord:
        """Transition computation state and persist structured failure details."""

        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM jobs WHERE job_id = ?", (job_id,)
            ).fetchone()
            if row is None:
                raise UnknownJob(job_id)
            current = ComputationState(row["computation_state"])
            require_state_transition(current, target)
            connection.execute(
                """
                UPDATE jobs SET computation_state = ?, error_code = ?,
                    error_message = ?, error_retryable = ?, local_traceback = ?,
                    updated_at = ? WHERE job_id = ?
                """,
                (
                    target.value,
                    error.code.value if error else None,
                    error.message if error else None,
                    int(error.retryable) if error else None,
                    local_traceback,
                    time.time(),
                    job_id,
                ),
            )
        return self.get_job(job_id)

    def complete_success(
        self,
        job_id: str,
        temporary_result_path: Path,
        *,
        max_array_bytes: int,
        retention_seconds: float,
    ) -> JobRecord:
        """Validate, publish, and record a successful result durably."""

        data = temporary_result_path.read_bytes()
        decode_array(
            data,
            max_size_bytes=max_array_bytes,
            error_code=ErrorCode.INVALID_RESULT,
        )
        digest = hashlib.sha256(data).hexdigest()
        now = time.time()
        with self._connect() as connection:
            # Recheck under the write lock so cancellation cannot be overwritten by
            # a result that completed at the same time.
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT computation_state, input_path FROM jobs WHERE job_id = ?",
                (job_id,),
            ).fetchone()
            if row is None:
                raise UnknownJob(job_id)
            current = ComputationState(row["computation_state"])
            require_state_transition(current, ComputationState.SUCCEEDED)
            result_path = Path(row["input_path"]).parent / "result.npy"
            os.replace(temporary_result_path, result_path)
            self._fsync_path(result_path)
            self._fsync_directory(result_path.parent)
            connection.execute(
                """
                UPDATE jobs SET computation_state = ?, result_state = ?,
                    result_path = ?, result_size_bytes = ?, result_sha256 = ?,
                    result_expires_at = ?, updated_at = ? WHERE job_id = ?
                """,
                (
                    ComputationState.SUCCEEDED.value,
                    ResultState.AVAILABLE.value,
                    str(result_path),
                    len(data),
                    digest,
                    now + retention_seconds,
                    now,
                    job_id,
                ),
            )
        return self.get_job(job_id)

    def expire_result(self, job_id: str) -> JobRecord:
        """Mark an available result expired and remove its artifact."""

        result_path: Path | None = None
        already_expired = False
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT result_state, result_path FROM jobs WHERE job_id = ?",
                (job_id,),
            ).fetchone()
            if row is None:
                raise UnknownJob(job_id)
            current = ResultState(row["result_state"])
            if current is ResultState.EXPIRED:
                already_expired = True
            elif current is not ResultState.AVAILABLE:
                raise ResultUnavailable()
            else:
                require_state_transition(current, ResultState.EXPIRED)
                result_path = (
                    Path(row["result_path"]) if row["result_path"] else None
                )
                connection.execute(
                    "UPDATE jobs SET result_state = ?, updated_at = ? "
                    "WHERE job_id = ?",
                    (ResultState.EXPIRED.value, time.time(), job_id),
                )
        if not already_expired and result_path is not None:
            result_path.unlink(missing_ok=True)
        return self.get_job(job_id)

    def acknowledge_result(self, job_id: str) -> JobRecord:
        """Idempotently acknowledge and remove a verified result artifact."""

        result_path: Path | None = None
        expired = False
        already_acknowledged = False
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT result_state, result_path, result_expires_at "
                "FROM jobs WHERE job_id = ?",
                (job_id,),
            ).fetchone()
            if row is None:
                raise UnknownJob(job_id)
            current = ResultState(row["result_state"])
            if current is ResultState.ACKNOWLEDGED:
                already_acknowledged = True
            elif current is ResultState.EXPIRED:
                raise ResultExpired()
            elif current is not ResultState.AVAILABLE:
                raise ResultUnavailable()
            else:
                result_path = (
                    Path(row["result_path"]) if row["result_path"] else None
                )
                if row["result_expires_at"] <= time.time():
                    target = ResultState.EXPIRED
                    expired = True
                else:
                    target = ResultState.ACKNOWLEDGED
                require_state_transition(current, target)
                connection.execute(
                    "UPDATE jobs SET result_state = ?, updated_at = ? "
                    "WHERE job_id = ?",
                    (target.value, time.time(), job_id),
                )
        if not already_acknowledged and result_path is not None:
            result_path.unlink(missing_ok=True)
        if expired:
            raise ResultExpired()
        return self.get_job(job_id)

    def ensure_terminal_callback(
        self,
        job_id: str,
        *,
        advertised_url: str,
        delivery_lifetime_seconds: float,
    ) -> CallbackRecord:
        """Create the job's single stable terminal callback if it is absent."""

        now = time.time()
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                "SELECT * FROM terminal_callbacks WHERE job_id = ?",
                (job_id,),
            ).fetchone()
            if existing is not None:
                return self._row_to_callback(existing)
            job = connection.execute(
                "SELECT * FROM jobs WHERE job_id = ?",
                (job_id,),
            ).fetchone()
            if job is None:
                raise UnknownJob(job_id)
            state = ComputationState(job["computation_state"])
            if state not in {
                ComputationState.SUCCEEDED,
                ComputationState.FAILED,
                ComputationState.CANCELLED,
            }:
                raise ValueError("terminal callback requires a terminal job")
            event_id = uuid.uuid4().hex
            base_url = advertised_url.rstrip("/")
            event: SuccessEvent | FailedEvent | CancelledEvent
            if state is ComputationState.SUCCEEDED:
                event = SuccessEvent.model_validate(
                    {
                        "event_id": event_id,
                        "job_id": job_id,
                        "result_url": f"{base_url}/v1/jobs/{job_id}/result",
                        "result_ack_url": (
                            f"{base_url}/v1/jobs/{job_id}/result-ack"
                        ),
                        "size_bytes": job["result_size_bytes"],
                        "sha256": job["result_sha256"],
                    }
                )
            else:
                error = ErrorInfo(
                    code=ErrorCode(job["error_code"]),
                    message=job["error_message"],
                    retryable=bool(job["error_retryable"]),
                )
                if state is ComputationState.FAILED:
                    event = FailedEvent(
                        event_id=event_id,
                        job_id=job_id,
                        error=error,
                    )
                else:
                    event = CancelledEvent(
                        event_id=event_id,
                        job_id=job_id,
                        error=error,
                    )
            payload_json = json.dumps(
                event.model_dump(mode="json"),
                separators=(",", ":"),
                sort_keys=True,
            )
            connection.execute(
                """
                INSERT INTO terminal_callbacks (
                    job_id, event_id, callback_url, payload_json, delivery_state,
                    next_attempt_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    job_id,
                    event_id,
                    job["callback_url"],
                    payload_json,
                    DeliveryState.PENDING.value,
                    now,
                    now + delivery_lifetime_seconds,
                ),
            )
        return self.get_callback(job_id)

    def get_callback(self, job_id: str) -> CallbackRecord:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM terminal_callbacks WHERE job_id = ?",
                (job_id,),
            ).fetchone()
        if row is None:
            raise UnknownJob(job_id)
        return self._row_to_callback(row)

    def next_due_callback(self, now: float | None = None) -> CallbackRecord | None:
        selected_now = time.time() if now is None else now
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT * FROM terminal_callbacks
                WHERE delivery_state IN ('pending', 'retrying')
                    AND next_attempt_at <= ?
                ORDER BY next_attempt_at LIMIT 1
                """,
                (selected_now,),
            ).fetchone()
        return self._row_to_callback(row) if row is not None else None

    def mark_callback_acknowledged(self, job_id: str) -> CallbackRecord:
        return self._set_callback_state(job_id, DeliveryState.ACKNOWLEDGED)

    def mark_callback_abandoned(
        self,
        job_id: str,
        *,
        error: str,
    ) -> CallbackRecord:
        return self._set_callback_state(
            job_id,
            DeliveryState.ABANDONED,
            error=error,
        )

    def mark_callback_retry(
        self,
        job_id: str,
        *,
        next_attempt_at: float,
        error: str,
    ) -> CallbackRecord:
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT delivery_state FROM terminal_callbacks WHERE job_id = ?",
                (job_id,),
            ).fetchone()
            if row is None:
                raise UnknownJob(job_id)
            current = DeliveryState(row["delivery_state"])
            require_state_transition(current, DeliveryState.RETRYING)
            connection.execute(
                """
                UPDATE terminal_callbacks SET delivery_state = ?,
                    attempt_count = attempt_count + 1, next_attempt_at = ?,
                    last_error = ? WHERE job_id = ?
                """,
                (
                    DeliveryState.RETRYING.value,
                    next_attempt_at,
                    error,
                    job_id,
                ),
            )
            connection.execute(
                """
                UPDATE jobs SET delivery_state = ?,
                    callback_attempt_count = callback_attempt_count + 1,
                    updated_at = ? WHERE job_id = ?
                """,
                (DeliveryState.RETRYING.value, time.time(), job_id),
            )
        return self.get_callback(job_id)

    def cleanup(
        self,
        *,
        now: float | None = None,
        diagnostic_retention_seconds: float,
    ) -> None:
        """Expire artifacts/delivery and remove fully settled old jobs."""

        selected_now = time.time() if now is None else now
        result_paths: list[Path] = []
        removable_directories: list[Path] = []
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            expired_results = connection.execute(
                """
                SELECT job_id, result_path FROM jobs
                WHERE result_state = 'available' AND result_expires_at <= ?
                """,
                (selected_now,),
            ).fetchall()
            for row in expired_results:
                if row["result_path"]:
                    result_paths.append(Path(row["result_path"]))
            connection.execute(
                """
                UPDATE jobs SET result_state = 'expired', updated_at = ?
                WHERE result_state = 'available' AND result_expires_at <= ?
                """,
                (selected_now, selected_now),
            )
            expired_callbacks = connection.execute(
                """
                SELECT job_id FROM terminal_callbacks
                WHERE delivery_state IN ('pending', 'retrying') AND expires_at <= ?
                """,
                (selected_now,),
            ).fetchall()
            for row in expired_callbacks:
                connection.execute(
                    """
                    UPDATE terminal_callbacks SET delivery_state = 'abandoned',
                        last_error = 'callback delivery lifetime expired'
                    WHERE job_id = ?
                    """,
                    (row["job_id"],),
                )
                connection.execute(
                    "UPDATE jobs SET delivery_state = 'abandoned', updated_at = ? "
                    "WHERE job_id = ?",
                    (selected_now, row["job_id"]),
                )
            settled = connection.execute(
                """
                SELECT job_id, input_path FROM jobs
                WHERE updated_at <= ?
                    AND computation_state IN ('succeeded', 'failed', 'cancelled')
                    AND delivery_state IN ('acknowledged', 'abandoned')
                    AND result_state IN ('unavailable', 'acknowledged', 'expired')
                """,
                (selected_now - diagnostic_retention_seconds,),
            ).fetchall()
            for row in settled:
                removable_directories.append(Path(row["input_path"]).parent)
                connection.execute(
                    "DELETE FROM jobs WHERE job_id = ?",
                    (row["job_id"],),
                )
        for path in result_paths:
            path.unlink(missing_ok=True)
        for directory in removable_directories:
            shutil.rmtree(directory, ignore_errors=True)

    def cleanup_temporary_files(self) -> None:
        """Remove crash leftovers before the foreground receiver starts workers."""

        # This runs only during startup. Periodic deletion could race the active
        # worker between fsync of result.npy.worker.tmp and its atomic publication.
        for temporary in self.jobs_directory.glob("*/.*.tmp"):
            temporary.unlink(missing_ok=True)
        for temporary in self.jobs_directory.glob("*/*.tmp"):
            temporary.unlink(missing_ok=True)

    def reconcile_interrupted_jobs(
        self,
        *,
        advertised_url: str,
        callback_delivery_lifetime_seconds: float,
    ) -> list[JobRecord]:
        """Fail jobs left nonterminal by a prior foreground receiver process."""

        error = ErrorInfo(
            code=ErrorCode.RECEIVER_RESTARTED,
            message="receiver restarted while the job was in progress",
            retryable=False,
        )
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            rows = connection.execute(
                """
                SELECT job_id FROM jobs
                WHERE computation_state IN ('accepted', 'running', 'cancelling')
                """
            ).fetchall()
            interrupted_ids = [row["job_id"] for row in rows]
            for job_id in interrupted_ids:
                connection.execute(
                    """
                    UPDATE jobs SET computation_state = 'failed', error_code = ?,
                        error_message = ?, error_retryable = 0, updated_at = ?
                    WHERE job_id = ?
                    """,
                    (error.code.value, error.message, time.time(), job_id),
                )
        reconciled: list[JobRecord] = []
        for job_id in interrupted_ids:
            # Callback creation is idempotent, so a crash during reconciliation is
            # repaired by the next foreground start without rerunning computation.
            self.ensure_terminal_callback(
                job_id,
                advertised_url=advertised_url,
                delivery_lifetime_seconds=callback_delivery_lifetime_seconds,
            )
            reconciled.append(self.get_job(job_id))
        return reconciled

    def _set_callback_state(
        self,
        job_id: str,
        target: DeliveryState,
        *,
        error: str | None = None,
    ) -> CallbackRecord:
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT delivery_state FROM terminal_callbacks WHERE job_id = ?",
                (job_id,),
            ).fetchone()
            if row is None:
                raise UnknownJob(job_id)
            current = DeliveryState(row["delivery_state"])
            require_state_transition(current, target)
            connection.execute(
                "UPDATE terminal_callbacks SET delivery_state = ?, last_error = ? "
                "WHERE job_id = ?",
                (target.value, error, job_id),
            )
            connection.execute(
                "UPDATE jobs SET delivery_state = ?, updated_at = ? WHERE job_id = ?",
                (target.value, time.time(), job_id),
            )
        return self.get_callback(job_id)

    @staticmethod
    def _validate_job_id(job_id: str) -> None:
        if not _SAFE_JOB_ID.fullmatch(job_id):
            raise ValueError("job_id must contain only letters, digits, '_' or '-'")

    @staticmethod
    def _write_atomic(path: Path, data: bytes) -> None:
        temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
        try:
            with temporary.open("xb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            JobStorage._fsync_directory(path.parent)
        finally:
            temporary.unlink(missing_ok=True)

    @staticmethod
    def _fsync_path(path: Path) -> None:
        with path.open("rb") as stream:
            os.fsync(stream.fileno())

    @staticmethod
    def _fsync_directory(path: Path) -> None:
        descriptor = os.open(path, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    @staticmethod
    def _row_to_job(row: sqlite3.Row) -> JobRecord:
        error = None
        if row["error_code"] is not None:
            error = ErrorInfo(
                code=ErrorCode(row["error_code"]),
                message=row["error_message"],
                retryable=bool(row["error_retryable"]),
            )
        return JobRecord(
            job_id=row["job_id"],
            idempotency_key=row["idempotency_key"],
            request_fingerprint=row["request_fingerprint"],
            metadata=json.loads(row["metadata_json"]),
            callback_url=row["callback_url"],
            computation_state=ComputationState(row["computation_state"]),
            delivery_state=DeliveryState(row["delivery_state"]),
            result_state=ResultState(row["result_state"]),
            error=error,
            local_traceback=row["local_traceback"],
            input_path=Path(row["input_path"]),
            input_size_bytes=row["input_size_bytes"],
            input_sha256=row["input_sha256"],
            result_path=Path(row["result_path"]) if row["result_path"] else None,
            result_size_bytes=row["result_size_bytes"],
            result_sha256=row["result_sha256"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            result_expires_at=row["result_expires_at"],
        )

    @staticmethod
    def _row_to_callback(row: sqlite3.Row) -> CallbackRecord:
        return CallbackRecord(
            job_id=row["job_id"],
            event_id=row["event_id"],
            callback_url=row["callback_url"],
            payload=json.loads(row["payload_json"]),
            delivery_state=DeliveryState(row["delivery_state"]),
            attempt_count=row["attempt_count"],
            next_attempt_at=row["next_attempt_at"],
            expires_at=row["expires_at"],
            last_error=row["last_error"],
        )
