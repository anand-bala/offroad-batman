from __future__ import annotations

import unittest

import numpy as np

from offroad_batman.jobs.processors import busywork


class RecordingContext:
    def __init__(self) -> None:
        self.cancellation_checks = 0
        self.heartbeats = 0

    def raise_if_cancelled(self) -> None:
        self.cancellation_checks += 1

    def heartbeat(self) -> None:
        self.heartbeats += 1


class BusyworkProcessorTests(unittest.TestCase):
    def test_busywork_exercises_context_and_returns_copy(self) -> None:
        original = np.arange(4)
        context = RecordingContext()

        result = busywork({"busywork_iterations": 2}, original, context)

        np.testing.assert_array_equal(result, original)
        self.assertIsNot(result, original)
        self.assertEqual(context.cancellation_checks, 2)
        self.assertEqual(context.heartbeats, 2)

    def test_busywork_rejects_invalid_iteration_count(self) -> None:
        with self.assertRaisesRegex(ValueError, "positive integer"):
            busywork({"busywork_iterations": 0}, np.arange(2), RecordingContext())
