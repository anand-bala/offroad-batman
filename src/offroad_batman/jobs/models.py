"""Wire models and independent job lifecycle states."""

from __future__ import annotations

from enum import Enum
from typing import Annotated, Literal

from pydantic import AnyHttpUrl, BaseModel, ConfigDict, Field, JsonValue

from .errors import ErrorCode, InvalidStateTransition


class ComputationState(str, Enum):
    ACCEPTED = "accepted"
    RUNNING = "running"
    CANCELLING = "cancelling"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELLED = "cancelled"


class DeliveryState(str, Enum):
    PENDING = "pending"
    RETRYING = "retrying"
    ACKNOWLEDGED = "acknowledged"
    ABANDONED = "abandoned"


class ResultState(str, Enum):
    UNAVAILABLE = "unavailable"
    AVAILABLE = "available"
    ACKNOWLEDGED = "acknowledged"
    EXPIRED = "expired"


State = ComputationState | DeliveryState | ResultState
StateKey = tuple[type[Enum], str]

_ALLOWED_TRANSITIONS: dict[StateKey, frozenset[str]] = {
    (ComputationState, ComputationState.ACCEPTED.value): frozenset(
        {
            ComputationState.RUNNING.value,
            ComputationState.CANCELLING.value,
            ComputationState.FAILED.value,
            ComputationState.CANCELLED.value,
        }
    ),
    (ComputationState, ComputationState.RUNNING.value): frozenset(
        {
            ComputationState.CANCELLING.value,
            ComputationState.SUCCEEDED.value,
            ComputationState.FAILED.value,
            ComputationState.CANCELLED.value,
        }
    ),
    (ComputationState, ComputationState.CANCELLING.value): frozenset(
        {ComputationState.CANCELLED.value, ComputationState.FAILED.value}
    ),
    (ComputationState, ComputationState.SUCCEEDED.value): frozenset(),
    (ComputationState, ComputationState.FAILED.value): frozenset(),
    (ComputationState, ComputationState.CANCELLED.value): frozenset(),
    (DeliveryState, DeliveryState.PENDING.value): frozenset(
        {
            DeliveryState.RETRYING.value,
            DeliveryState.ACKNOWLEDGED.value,
            DeliveryState.ABANDONED.value,
        }
    ),
    (DeliveryState, DeliveryState.RETRYING.value): frozenset(
        {
            DeliveryState.RETRYING.value,
            DeliveryState.ACKNOWLEDGED.value,
            DeliveryState.ABANDONED.value,
        }
    ),
    (DeliveryState, DeliveryState.ACKNOWLEDGED.value): frozenset(),
    (DeliveryState, DeliveryState.ABANDONED.value): frozenset(),
    (ResultState, ResultState.UNAVAILABLE.value): frozenset(
        {ResultState.AVAILABLE.value, ResultState.EXPIRED.value}
    ),
    (ResultState, ResultState.AVAILABLE.value): frozenset(
        {ResultState.ACKNOWLEDGED.value, ResultState.EXPIRED.value}
    ),
    (ResultState, ResultState.ACKNOWLEDGED.value): frozenset(),
    (ResultState, ResultState.EXPIRED.value): frozenset(),
}


def require_state_transition(current: State, target: State) -> None:
    """Validate an idempotent transition within one lifecycle state machine."""

    key = (type(current), current.value)
    if type(current) is not type(target) or (
        current != target and target.value not in _ALLOWED_TRANSITIONS[key]
    ):
        raise InvalidStateTransition(current.value, target.value)


class WireModel(BaseModel):
    """Base for strict protocol payloads."""

    model_config = ConfigDict(extra="forbid")


class ErrorInfo(WireModel):
    code: ErrorCode
    message: str = Field(min_length=1)
    retryable: bool = False


class JobSubmission(WireModel):
    metadata: dict[str, JsonValue]
    callback_url: AnyHttpUrl


class JobAccepted(WireModel):
    job_id: str = Field(min_length=1)
    state: Literal[ComputationState.ACCEPTED] = ComputationState.ACCEPTED
    status_url: AnyHttpUrl


class JobStatus(WireModel):
    job_id: str = Field(min_length=1)
    computation_state: ComputationState
    delivery_state: DeliveryState
    result_state: ResultState
    error: ErrorInfo | None = None


class ResultAcknowledgement(WireModel):
    job_id: str = Field(min_length=1)
    result_state: Literal[ResultState.ACKNOWLEDGED] = ResultState.ACKNOWLEDGED


class TerminalEventBase(WireModel):
    event_id: str = Field(min_length=1)
    job_id: str = Field(min_length=1)


class SuccessEvent(TerminalEventBase):
    state: Literal[ComputationState.SUCCEEDED] = ComputationState.SUCCEEDED
    result_url: AnyHttpUrl
    result_ack_url: AnyHttpUrl
    content_type: Literal["application/x-npy"] = "application/x-npy"
    size_bytes: int = Field(ge=0)
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")


class FailedEvent(TerminalEventBase):
    state: Literal[ComputationState.FAILED] = ComputationState.FAILED
    error: ErrorInfo


class CancelledEvent(TerminalEventBase):
    state: Literal[ComputationState.CANCELLED] = ComputationState.CANCELLED
    error: ErrorInfo


TerminalEvent = Annotated[
    SuccessEvent | FailedEvent | CancelledEvent,
    Field(discriminator="state"),
]


class CallbackReceipt(WireModel):
    event_id: str = Field(min_length=1)
    duplicate: bool
