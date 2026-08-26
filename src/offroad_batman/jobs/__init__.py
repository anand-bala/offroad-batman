"""Foundational models and utilities for asynchronous MANET NumPy jobs."""

from .array_io import EncodedArray, decode_array, encode_array, verify_payload
from .client import Client, RemoteJob
from .config import ReceiverSettings, default_state_directory
from .errors import ArrayValidationError, ErrorCode, InvalidStateTransition, JobsError
from .inbox import CallbackInbox
from .models import (
    CallbackReceipt,
    CancelledEvent,
    ComputationState,
    DeliveryState,
    ErrorInfo,
    FailedEvent,
    JobAccepted,
    JobStatus,
    JobSubmission,
    ResultAcknowledgement,
    ResultState,
    SuccessEvent,
    TerminalEvent,
    require_state_transition,
)

__all__ = [
    "ArrayValidationError",
    "CancelledEvent",
    "CallbackReceipt",
    "CallbackInbox",
    "Client",
    "ComputationState",
    "DeliveryState",
    "EncodedArray",
    "ErrorCode",
    "ErrorInfo",
    "FailedEvent",
    "InvalidStateTransition",
    "JobAccepted",
    "JobStatus",
    "JobSubmission",
    "JobsError",
    "ReceiverSettings",
    "RemoteJob",
    "ResultAcknowledgement",
    "ResultState",
    "SuccessEvent",
    "TerminalEvent",
    "decode_array",
    "default_state_directory",
    "encode_array",
    "require_state_transition",
    "verify_payload",
]
