from __future__ import annotations

import socket
import threading
import time
from pathlib import Path

import httpx
import pytest
import uvicorn

from offroad_batman.jobs.config import ReceiverSettings
from offroad_batman.jobs.receiver.app import create_receiver_app
from offroad_batman.jobs.receiver.service import ReceiverService


def test_uvicorn_accepts_ipv6_loopback_requests(tmp_path: Path) -> None:
    try:
        probe = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        probe.bind(("::1", 0))
    except OSError:
        pytest.skip("IPv6 loopback is unavailable")
    port = probe.getsockname()[1]
    probe.close()

    service = ReceiverService(ReceiverSettings(state_directory=tmp_path))
    server = uvicorn.Server(
        uvicorn.Config(
            create_receiver_app(service),
            host="::1",
            port=port,
            log_level="critical",
            lifespan="off",
        )
    )
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 5
    while not server.started and thread.is_alive() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert server.started
    try:
        with httpx.Client(trust_env=False, timeout=2) as client:
            response = client.get(f"http://[::1]:{port}/v1/jobs/missing")
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "invalid_submission"
    finally:
        server.should_exit = True
        thread.join(timeout=5)
    assert thread.is_alive() is False
