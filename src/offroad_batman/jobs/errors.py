"""Stable errors shared by the MANET jobs library."""

from __future__ import annotations

from enum import Enum


class ErrorCode(str, Enum):
    """Machine-readable job failure codes."""

    INVALID_SUBMISSION = "invalid_submission"
    RECEIVER_BUSY = "receiver_busy"
    WORKER_EXCEPTION = "worker_exception"
    WORKER_CRASHED = "worker_crashed"
    WORKER_STARTUP_TIMEOUT = "worker_startup_timeout"
    WORKER_UNRESPONSIVE = "worker_unresponsive"
    PROGRESS_TIMEOUT = "progress_timeout"
    INVALID_RESULT = "invalid_result"
    CANCELLED = "cancelled"
    RECEIVER_RESTARTED = "receiver_restarted"
    RECEIVER_ERROR = "receiver_error"
    RESULT_EXPIRED = "result_expired"


class JobsError(Exception):
    """Base class for library errors with stable machine-readable codes."""

    def __init__(
        self,
        code: ErrorCode,
        message: str,
        *,
        retryable: bool = False,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable


class ArrayValidationError(JobsError):
    """Raised when an input or result is not a supported NumPy payload."""

    def __init__(
        self,
        message: str,
        *,
        code: ErrorCode = ErrorCode.INVALID_SUBMISSION,
    ) -> None:
        super().__init__(code, message, retryable=False)


class InvalidStateTransition(JobsError):
    """Raised when a state machine transition is not permitted."""

    def __init__(self, current: str, target: str) -> None:
        super().__init__(
            ErrorCode.RECEIVER_ERROR,
            f"invalid state transition: {current} -> {target}",
            retryable=False,
        )


class ReceiverBusy(JobsError):
    """Raised when another job currently occupies the execution slot."""

    def __init__(self, retry_after_seconds: int = 5) -> None:
        super().__init__(
            ErrorCode.RECEIVER_BUSY,
            "receiver already has a nonterminal job",
            retryable=True,
        )
        self.retry_after_seconds = retry_after_seconds


class IdempotencyConflict(JobsError):
    """Raised when an idempotency key is reused for a different request."""

    def __init__(self) -> None:
        super().__init__(
            ErrorCode.INVALID_SUBMISSION,
            "idempotency key was already used for a different request",
            retryable=False,
        )


class UnknownJob(JobsError):
    """Raised when a job ID is absent from durable storage."""

    def __init__(self, job_id: str) -> None:
        super().__init__(
            ErrorCode.INVALID_SUBMISSION,
            f"unknown job: {job_id}",
            retryable=False,
        )


class ResultUnavailable(JobsError):
    """Raised when a job has no downloadable result."""

    def __init__(self, message: str = "job result is not available") -> None:
        super().__init__(ErrorCode.RECEIVER_ERROR, message, retryable=False)


class ResultExpired(JobsError):
    """Raised after a result's retention deadline."""

    def __init__(self) -> None:
        super().__init__(
            ErrorCode.RESULT_EXPIRED,
            "job result has expired",
            retryable=False,
        )
