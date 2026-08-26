"""Spawn-safe child worker and processor context."""

from __future__ import annotations

import importlib
import os
import threading
import time
import traceback
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any, Protocol, cast

import numpy as np
import numpy.typing as npt
from pydantic import JsonValue

from ..array_io import encode_array
from ..errors import ArrayValidationError


class MessageQueue(Protocol):
    def put(self, item: tuple[str, Any]) -> None: ...


class CancellationFlag(Protocol):
    def is_set(self) -> bool: ...


class WorkerCancelled(Exception):
    """Internal cooperative-cancellation signal."""


class ChildProcessorContext:
    """Child-side cancellation and explicit progress interface."""

    def __init__(
        self,
        cancellation: CancellationFlag,
        messages: MessageQueue,
    ) -> None:
        self._cancellation = cancellation
        self._messages = messages

    def raise_if_cancelled(self) -> None:
        if self._cancellation.is_set():
            raise WorkerCancelled("job was cancelled")

    def heartbeat(self) -> None:
        self._messages.put(("progress", time.monotonic()))


Processor = Callable[
    [Mapping[str, JsonValue], npt.NDArray[Any], ChildProcessorContext],
    npt.NDArray[Any],
]


def load_processor(specification: str) -> Processor:
    """Load an importable top-level processor from `module:function`."""

    module_name, separator, attribute_name = specification.partition(":")
    if not separator or not module_name or not attribute_name or "." in attribute_name:
        raise ValueError("processor must name a top-level module:function")
    processor = getattr(importlib.import_module(module_name), attribute_name)
    if not callable(processor):
        raise TypeError(f"processor is not callable: {specification}")
    return cast(Processor, processor)


def run_worker(
    processor_specification: str,
    metadata: Mapping[str, JsonValue],
    input_path: str,
    temporary_result_path: str,
    cancellation: CancellationFlag,
    messages: MessageQueue,
    heartbeat_interval_seconds: float,
    max_array_bytes: int,
) -> None:
    """Spawn entry point: run one processor and report a structured outcome."""

    runtime_stop = threading.Event()

    def emit_runtime_heartbeats() -> None:
        while not runtime_stop.is_set():
            messages.put(("runtime", time.monotonic()))
            runtime_stop.wait(heartbeat_interval_seconds)

    runtime_thread = threading.Thread(
        target=emit_runtime_heartbeats,
        name="manet-job-runtime-heartbeat",
        daemon=True,
    )
    runtime_thread.start()
    try:
        processor = load_processor(processor_specification)
        with Path(input_path).open("rb") as input_stream:
            array = np.load(input_stream, allow_pickle=False)
        if not isinstance(array, np.ndarray) or array.dtype.hasobject:
            raise ValueError("input is not a supported NumPy array")
        context = ChildProcessorContext(cancellation, messages)
        context.raise_if_cancelled()
        messages.put(("processor_started", time.monotonic()))
        result = processor(metadata, array, context)
        context.raise_if_cancelled()
        encoded = encode_array(result, max_size_bytes=max_array_bytes)
        result_path = Path(temporary_result_path)
        with result_path.open("xb") as result_stream:
            result_stream.write(encoded.data)
            result_stream.flush()
            os.fsync(result_stream.fileno())
        messages.put(("outcome", {"kind": "succeeded"}))
    except WorkerCancelled:
        messages.put(("outcome", {"kind": "cancelled"}))
    except ArrayValidationError as exc:
        messages.put(
            (
                "outcome",
                {
                    "kind": "invalid_result",
                    "message": exc.message,
                    "traceback": traceback.format_exc(),
                },
            )
        )
    except BaseException as exc:
        messages.put(
            (
                "outcome",
                {
                    "kind": "failed",
                    "message": str(exc) or type(exc).__name__,
                    "traceback": traceback.format_exc(),
                },
            )
        )
    finally:
        runtime_stop.set()
        runtime_thread.join(timeout=heartbeat_interval_seconds)
