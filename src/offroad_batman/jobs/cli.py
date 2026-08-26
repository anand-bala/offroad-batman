"""Foreground commands for the fixed olo/ragnarhorn job workflow."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import uvicorn

from .array_io import decode_array, encode_array
from .client import Client
from .config import (
    DEFAULT_BIND_HOST,
    DEFAULT_CALLBACK_URL,
    DEFAULT_PORT,
    DEFAULT_PROCESSOR,
    DEFAULT_RECEIVER_URL,
    ReceiverSettings,
    default_state_directory,
)
from .inbox import CallbackInbox, create_callback_inbox_app
from .receiver import ReceiverService, create_receiver_app


def build_parser() -> argparse.ArgumentParser:
    """Build the command parser without performing network or file operations."""

    parser = argparse.ArgumentParser(prog="offroad-batman-jobs")
    commands = parser.add_subparsers(dest="command", required=True)

    receive = commands.add_parser("receive", help="run olo's foreground receiver")
    receive.add_argument("--host", default=DEFAULT_BIND_HOST)
    receive.add_argument("--port", type=int, default=DEFAULT_PORT)
    receive.add_argument("--processor", default=DEFAULT_PROCESSOR)
    receive.add_argument("--state-dir", type=Path, default=default_state_directory())
    receive.add_argument("--once", action="store_true")

    submit = commands.add_parser("submit", help="submit from ragnarhorn and wait")
    submit.add_argument("--receiver", default=DEFAULT_RECEIVER_URL)
    submit.add_argument("--input", type=Path, required=True)
    submit.add_argument("--metadata", type=Path, required=True)
    submit.add_argument("--output", type=Path, default=Path("result.npy"))
    submit.add_argument("--host", default=DEFAULT_BIND_HOST)
    submit.add_argument("--port", type=int, default=DEFAULT_PORT)
    submit.add_argument("--callback-url", default=DEFAULT_CALLBACK_URL)
    submit.add_argument(
        "--state-dir",
        type=Path,
        default=default_state_directory() / "inbox",
    )
    submit.add_argument("--idempotency-key")
    submit.add_argument("--callback-timeout", type=float, default=24 * 60 * 60)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run a foreground receiver or a submit-and-wait workflow."""

    arguments = build_parser().parse_args(argv)
    if arguments.command == "receive":
        asyncio.run(_receive(arguments))
        return 0
    return asyncio.run(_submit(arguments))


async def _receive(arguments: argparse.Namespace) -> None:
    advertised_url = f"http://olo.mesh:{arguments.port}"
    settings = ReceiverSettings(
        processor=arguments.processor,
        state_directory=arguments.state_dir,
        advertised_url=advertised_url,
    )
    service = ReceiverService(settings)
    server = uvicorn.Server(
        uvicorn.Config(
            create_receiver_app(service),
            host=arguments.host,
            port=arguments.port,
            workers=1,
        )
    )
    if not arguments.once:
        await server.serve()
        return

    async def stop_after_one_job() -> None:
        await service.wait_until_once_complete()
        server.should_exit = True

    monitor = asyncio.create_task(stop_after_one_job())
    try:
        await server.serve()
    finally:
        monitor.cancel()
        await asyncio.gather(monitor, return_exceptions=True)


async def _submit(arguments: argparse.Namespace) -> int:
    metadata = _read_metadata(arguments.metadata)
    input_array = decode_array(arguments.input.read_bytes())
    inbox = CallbackInbox(arguments.state_dir)
    server = uvicorn.Server(
        uvicorn.Config(
            create_callback_inbox_app(inbox),
            host=arguments.host,
            port=arguments.port,
            workers=1,
        )
    )
    server_task = asyncio.create_task(server.serve())
    try:
        await _wait_for_server_start(server, server_task)
        async with Client() as client:
            job = await client.submit(
                receiver_url=arguments.receiver,
                array=input_array,
                metadata=metadata,
                callback_url=arguments.callback_url,
                idempotency_key=arguments.idempotency_key,
            )
            event = await inbox.wait_for_job(
                job.job_id,
                timeout=arguments.callback_timeout,
            )
            if event.payload["state"] != "succeeded":
                print(json.dumps(event.payload, sort_keys=True))
                return 1
            result = await job.fetch_and_acknowledge(
                expected_size_bytes=int(event.payload["size_bytes"]),
                expected_sha256=str(event.payload["sha256"]),
            )
            _write_result(arguments.output, encode_array(result).data)
            print(str(arguments.output))
            return 0
    finally:
        server.should_exit = True
        await server_task


async def _wait_for_server_start(
    server: uvicorn.Server,
    task: asyncio.Task[None],
) -> None:
    while not server.started:
        if task.done():
            await task
            raise RuntimeError("callback inbox stopped before startup")
        await asyncio.sleep(0.01)


def _read_metadata(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("metadata file must contain a JSON object")
    return payload


def _write_result(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with temporary.open("wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
