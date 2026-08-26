from __future__ import annotations

import unittest
from pathlib import Path

from offroad_batman.jobs.config import (
    DEFAULT_PROCESSOR,
    DEFAULT_RECEIVER_URL,
    ReceiverSettings,
    default_state_directory,
)


class ConfigTests(unittest.TestCase):
    def test_xdg_state_directory(self) -> None:
        path = default_state_directory({"XDG_STATE_HOME": "/state"})

        self.assertEqual(path, Path("/state/offroad-batman/jobs"))

    def test_state_directory_falls_back_below_user_home(self) -> None:
        path = default_state_directory({}, home=Path("/home/tester"))

        self.assertEqual(path, Path("/home/tester/.local/state/offroad-batman/jobs"))

    def test_receiver_defaults_match_initial_topology(self) -> None:
        settings = ReceiverSettings(state_directory=Path("/tmp/jobs-test-state"))

        self.assertEqual(settings.processor, DEFAULT_PROCESSOR)
        self.assertEqual(settings.advertised_url, DEFAULT_RECEIVER_URL)
        self.assertEqual(settings.max_array_bytes, 4 * 1024 * 1024)

    def test_receiver_rejects_invalid_values(self) -> None:
        with self.assertRaisesRegex(ValueError, "module:function"):
            ReceiverSettings(processor="busywork")
        for invalid_url in (
            "https://olo.mesh:8080",
            "http://",
            "http:///v1/jobs",
            "http://olo.mesh:not-a-port",
        ):
            with self.subTest(advertised_url=invalid_url):
                with self.assertRaisesRegex(ValueError, "absolute HTTP"):
                    ReceiverSettings(advertised_url=invalid_url)
        with self.assertRaisesRegex(ValueError, "durations"):
            ReceiverSettings(progress_timeout_seconds=0)
        with self.assertRaisesRegex(ValueError, "max_array_bytes"):
            ReceiverSettings(max_array_bytes=0)
