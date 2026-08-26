"""Safe NumPy `.npy` encoding, decoding, and integrity checks."""

from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass
from typing import Any

import numpy as np
import numpy.typing as npt

from .errors import ArrayValidationError, ErrorCode


@dataclass(frozen=True)
class EncodedArray:
    data: bytes
    size_bytes: int
    sha256: str


def _validate_array(array: object, *, code: ErrorCode) -> npt.NDArray[Any]:
    if not isinstance(array, np.ndarray):
        raise ArrayValidationError("payload must contain one NumPy array", code=code)
    if array.dtype.hasobject:
        raise ArrayValidationError("object-dtype arrays are not supported", code=code)
    return array


def encode_array(
    array: npt.NDArray[Any],
    *,
    max_size_bytes: int | None = None,
) -> EncodedArray:
    """Encode one non-object array as an unpickled `.npy` payload."""

    validated = _validate_array(array, code=ErrorCode.INVALID_SUBMISSION)
    output = io.BytesIO()
    np.save(output, validated, allow_pickle=False)
    data = output.getvalue()
    if max_size_bytes is not None and len(data) > max_size_bytes:
        raise ArrayValidationError(
            f"encoded array exceeds the {max_size_bytes}-byte limit"
        )
    return EncodedArray(
        data=data,
        size_bytes=len(data),
        sha256=hashlib.sha256(data).hexdigest(),
    )


def decode_array(
    data: bytes,
    *,
    max_size_bytes: int | None = None,
    error_code: ErrorCode = ErrorCode.INVALID_SUBMISSION,
) -> npt.NDArray[Any]:
    """Decode exactly one non-object `.npy` payload with pickling disabled."""

    if max_size_bytes is not None and len(data) > max_size_bytes:
        raise ArrayValidationError(
            f"array payload exceeds the {max_size_bytes}-byte limit",
            code=error_code,
        )
    source = io.BytesIO(data)
    try:
        array = np.load(source, allow_pickle=False)
    except (OSError, ValueError, EOFError) as exc:
        raise ArrayValidationError(
            "payload is not a valid unpickled .npy array",
            code=error_code,
        ) from exc
    validated = _validate_array(array, code=error_code)
    if source.tell() != len(data):
        raise ArrayValidationError("payload contains trailing data", code=error_code)
    return validated


def verify_payload(data: bytes, *, size_bytes: int, sha256: str) -> None:
    """Verify a result payload before it is decoded or acknowledged."""

    if len(data) != size_bytes:
        raise ArrayValidationError(
            "array payload size does not match the advertised size",
            code=ErrorCode.INVALID_RESULT,
        )
    actual_digest = hashlib.sha256(data).hexdigest()
    if actual_digest != sha256.lower():
        raise ArrayValidationError(
            "array payload digest does not match the advertised SHA-256",
            code=ErrorCode.INVALID_RESULT,
        )
