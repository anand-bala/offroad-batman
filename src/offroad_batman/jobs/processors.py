"""Temporary importable processors used during initial integration."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any, Protocol

import numpy as np
import numpy.typing as npt
from pydantic import JsonValue


class ProcessorContext(Protocol):
    """Operations available to processor functions."""

    def raise_if_cancelled(self) -> None: ...

    def heartbeat(self) -> None: ...


def busywork(
    metadata: Mapping[str, JsonValue],
    array: npt.NDArray[Any],
    context: ProcessorContext,
) -> npt.NDArray[Any]:
    """Exercise the processor contract and return an independent array copy."""

    iterations = metadata.get("busywork_iterations", 3)
    if (
        not isinstance(iterations, int)
        or isinstance(iterations, bool)
        or iterations < 1
    ):
        raise ValueError("busywork_iterations must be a positive integer")
    result = np.array(array, copy=True)
    for _ in range(iterations):
        context.raise_if_cancelled()
        np.sum(result)
        context.heartbeat()
    return result
