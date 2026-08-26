from __future__ import annotations

import os
import threading
import time
from collections.abc import Mapping
from typing import Any

import numpy as np
import numpy.typing as npt
from pydantic import JsonValue

from offroad_batman.jobs.processors import ProcessorContext


def double(
    metadata: Mapping[str, JsonValue],
    array: npt.NDArray[Any],
    context: ProcessorContext,
) -> npt.NDArray[Any]:
    del metadata
    context.raise_if_cancelled()
    context.heartbeat()
    return array * 2


def fail(
    metadata: Mapping[str, JsonValue],
    array: npt.NDArray[Any],
    context: ProcessorContext,
) -> npt.NDArray[Any]:
    del metadata, array, context
    raise RuntimeError("fixture processor failed")


def crash(
    metadata: Mapping[str, JsonValue],
    array: npt.NDArray[Any],
    context: ProcessorContext,
) -> npt.NDArray[Any]:
    del metadata, array, context
    os._exit(7)


def cooperative_wait(
    metadata: Mapping[str, JsonValue],
    array: npt.NDArray[Any],
    context: ProcessorContext,
) -> npt.NDArray[Any]:
    del metadata
    while True:
        context.raise_if_cancelled()
        context.heartbeat()
        time.sleep(0.01)
    return array


def uncooperative_wait(
    metadata: Mapping[str, JsonValue],
    array: npt.NDArray[Any],
    context: ProcessorContext,
) -> npt.NDArray[Any]:
    del metadata, context
    time.sleep(5)
    return array


def no_progress(
    metadata: Mapping[str, JsonValue],
    array: npt.NDArray[Any],
    context: ProcessorContext,
) -> npt.NDArray[Any]:
    del metadata, context
    time.sleep(5)
    return array


def object_result(
    metadata: Mapping[str, JsonValue],
    array: npt.NDArray[Any],
    context: ProcessorContext,
) -> npt.NDArray[Any]:
    del metadata, array, context
    return np.array([object()], dtype=object)


def delayed_process_exit(
    metadata: Mapping[str, JsonValue],
    array: npt.NDArray[Any],
    context: ProcessorContext,
) -> npt.NDArray[Any]:
    del metadata
    context.heartbeat()
    cleanup = threading.Thread(target=time.sleep, args=(0.3,), daemon=False)
    cleanup.start()
    return np.array(array, copy=True)
