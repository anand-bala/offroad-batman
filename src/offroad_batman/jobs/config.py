"""Configuration defaults for foreground MANET job processes."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

DEFAULT_PORT = 8080
DEFAULT_BIND_HOST = "::"
DEFAULT_RECEIVER_URL = f"http://olo.mesh:{DEFAULT_PORT}"
DEFAULT_CALLBACK_URL = f"http://ragnarhorn.mesh:{DEFAULT_PORT}/v1/callbacks"
DEFAULT_PROCESSOR = "offroad_batman.jobs.processors:busywork"
DEFAULT_MAX_ARRAY_BYTES = 4 * 1024 * 1024
DEFAULT_MAX_REQUEST_BYTES = DEFAULT_MAX_ARRAY_BYTES + 256 * 1024


def default_state_directory(
    environ: Mapping[str, str] | None = None,
    *,
    home: Path | None = None,
) -> Path:
    """Return the user-owned XDG state directory for this library."""

    environment = os.environ if environ is None else environ
    configured = environment.get("XDG_STATE_HOME")
    state_home = Path(configured).expanduser() if configured else (
        (Path.home() if home is None else home) / ".local" / "state"
    )
    return state_home / "offroad-batman" / "jobs"


@dataclass(frozen=True)
class ReceiverSettings:
    """Validated receiver defaults shared by the future API and CLI."""

    processor: str = DEFAULT_PROCESSOR
    state_directory: Path | None = None
    advertised_url: str = DEFAULT_RECEIVER_URL
    result_retention_seconds: float = 3600
    heartbeat_interval_seconds: float = 2
    worker_startup_timeout_seconds: float = 30
    runtime_heartbeat_timeout_seconds: float = 15
    progress_timeout_seconds: float = 300
    cancellation_grace_seconds: float = 5
    termination_grace_seconds: float = 2
    post_outcome_exit_timeout_seconds: float = 10
    monitor_interval_seconds: float = 0.1
    max_array_bytes: int = DEFAULT_MAX_ARRAY_BYTES
    max_request_bytes: int = DEFAULT_MAX_REQUEST_BYTES
    max_metadata_bytes: int = 64 * 1024
    callback_delivery_lifetime_seconds: float = 24 * 60 * 60
    callback_initial_backoff_seconds: float = 1
    callback_max_backoff_seconds: float = 60
    cleanup_interval_seconds: float = 60
    diagnostic_retention_seconds: float = 24 * 60 * 60

    def __post_init__(self) -> None:
        if ":" not in self.processor:
            raise ValueError("processor must use the 'module:function' form")
        try:
            advertised_url = urlsplit(self.advertised_url)
            hostname = advertised_url.hostname
            advertised_url.port
        except ValueError as exc:
            raise ValueError("advertised_url must be an absolute HTTP URL") from exc
        if advertised_url.scheme != "http" or not hostname:
            raise ValueError("advertised_url must be an absolute HTTP URL")
        durations = (
            self.result_retention_seconds,
            self.heartbeat_interval_seconds,
            self.worker_startup_timeout_seconds,
            self.runtime_heartbeat_timeout_seconds,
            self.progress_timeout_seconds,
            self.cancellation_grace_seconds,
            self.termination_grace_seconds,
            self.post_outcome_exit_timeout_seconds,
            self.monitor_interval_seconds,
            self.callback_delivery_lifetime_seconds,
            self.callback_initial_backoff_seconds,
            self.callback_max_backoff_seconds,
            self.cleanup_interval_seconds,
            self.diagnostic_retention_seconds,
        )
        if any(value <= 0 for value in durations):
            raise ValueError("receiver durations must be positive")
        if self.max_array_bytes <= 0:
            raise ValueError("max_array_bytes must be positive")
        if self.max_request_bytes <= self.max_array_bytes:
            raise ValueError("max_request_bytes must exceed max_array_bytes")
        if self.max_metadata_bytes <= 0:
            raise ValueError("max_metadata_bytes must be positive")
        if self.callback_max_backoff_seconds < self.callback_initial_backoff_seconds:
            raise ValueError(
                "callback maximum backoff must not be below its initial backoff"
            )
        if self.state_directory is None:
            object.__setattr__(self, "state_directory", default_state_directory())
