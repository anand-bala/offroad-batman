from __future__ import annotations

import unittest

from pydantic import TypeAdapter, ValidationError

from offroad_batman.jobs.errors import ErrorCode, InvalidStateTransition
from offroad_batman.jobs.models import (
    ComputationState,
    DeliveryState,
    ErrorInfo,
    JobAccepted,
    ResultState,
    SuccessEvent,
    TerminalEvent,
    require_state_transition,
)


class ModelTests(unittest.TestCase):
    def test_job_acknowledgement_serializes_as_wire_data(self) -> None:
        accepted = JobAccepted(
            job_id="job-1",
            status_url="http://olo.mesh:8080/v1/jobs/job-1",
        )

        self.assertEqual(
            accepted.model_dump(mode="json"),
            {
                "job_id": "job-1",
                "state": "accepted",
                "status_url": "http://olo.mesh:8080/v1/jobs/job-1",
            },
        )

    def test_wire_models_reject_extra_fields(self) -> None:
        with self.assertRaises(ValidationError):
            ErrorInfo(
                code=ErrorCode.WORKER_EXCEPTION,
                message="processor failed",
                secret_traceback="hidden",
            )

    def test_terminal_event_is_discriminated_by_state(self) -> None:
        event = TypeAdapter(TerminalEvent).validate_python(
            {
                "event_id": "event-1",
                "job_id": "job-1",
                "state": "succeeded",
                "result_url": "http://olo.mesh:8080/v1/jobs/job-1/result",
                "result_ack_url": "http://olo.mesh:8080/v1/jobs/job-1/result-ack",
                "content_type": "application/x-npy",
                "size_bytes": 128,
                "sha256": "a" * 64,
            }
        )

        self.assertIsInstance(event, SuccessEvent)

    def test_state_transitions_are_independent_and_idempotent(self) -> None:
        require_state_transition(ComputationState.ACCEPTED, ComputationState.RUNNING)
        require_state_transition(DeliveryState.RETRYING, DeliveryState.RETRYING)
        require_state_transition(
            DeliveryState.ACKNOWLEDGED,
            DeliveryState.ACKNOWLEDGED,
        )
        require_state_transition(ResultState.AVAILABLE, ResultState.ACKNOWLEDGED)
        require_state_transition(
            ResultState.ACKNOWLEDGED,
            ResultState.ACKNOWLEDGED,
        )

        with self.assertRaises(InvalidStateTransition):
            require_state_transition(
                ComputationState.SUCCEEDED,
                ComputationState.RUNNING,
            )
        with self.assertRaises(InvalidStateTransition):
            require_state_transition(
                DeliveryState.ACKNOWLEDGED,
                ResultState.ACKNOWLEDGED,
            )
        with self.assertRaises(InvalidStateTransition):
            require_state_transition(
                ResultState.ACKNOWLEDGED,
                DeliveryState.ACKNOWLEDGED,
            )
