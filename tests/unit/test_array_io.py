from __future__ import annotations

import io
import unittest

import numpy as np

from offroad_batman.jobs.array_io import decode_array, encode_array, verify_payload
from offroad_batman.jobs.errors import ArrayValidationError, ErrorCode


class ArrayIoTests(unittest.TestCase):
    def test_round_trip_records_integrity_metadata(self) -> None:
        original = np.arange(12, dtype=np.float32).reshape(3, 4)

        encoded = encode_array(original)
        decoded = decode_array(encoded.data)

        np.testing.assert_array_equal(decoded, original)
        self.assertEqual(encoded.size_bytes, len(encoded.data))
        verify_payload(
            encoded.data,
            size_bytes=encoded.size_bytes,
            sha256=encoded.sha256,
        )

    def test_encode_rejects_object_dtype(self) -> None:
        array = np.array([{"unsafe": True}], dtype=object)

        with self.assertRaisesRegex(ArrayValidationError, "object-dtype"):
            encode_array(array)

    def test_decode_rejects_pickled_object_dtype(self) -> None:
        output = io.BytesIO()
        np.save(output, np.array([object()], dtype=object), allow_pickle=True)

        with self.assertRaises(ArrayValidationError) as raised:
            decode_array(output.getvalue())

        self.assertEqual(raised.exception.code, ErrorCode.INVALID_SUBMISSION)

    def test_decode_rejects_corruption_and_trailing_data(self) -> None:
        with self.assertRaises(ArrayValidationError):
            decode_array(b"not an npy file")

        encoded = encode_array(np.arange(3))
        with self.assertRaisesRegex(ArrayValidationError, "trailing"):
            decode_array(encoded.data + b"extra")

    def test_size_limit_is_checked_for_encoding_and_decoding(self) -> None:
        array = np.arange(32, dtype=np.uint8)
        encoded = encode_array(array)

        with self.assertRaisesRegex(ArrayValidationError, "limit"):
            encode_array(array, max_size_bytes=encoded.size_bytes - 1)
        with self.assertRaisesRegex(ArrayValidationError, "limit"):
            decode_array(encoded.data, max_size_bytes=encoded.size_bytes - 1)

    def test_verify_payload_rejects_size_and_digest_mismatches(self) -> None:
        encoded = encode_array(np.arange(3))

        with self.assertRaises(ArrayValidationError) as size_error:
            verify_payload(
                encoded.data,
                size_bytes=encoded.size_bytes + 1,
                sha256=encoded.sha256,
            )
        self.assertEqual(size_error.exception.code, ErrorCode.INVALID_RESULT)

        with self.assertRaises(ArrayValidationError) as digest_error:
            verify_payload(
                encoded.data,
                size_bytes=encoded.size_bytes,
                sha256="0" * 64,
            )
        self.assertEqual(digest_error.exception.code, ErrorCode.INVALID_RESULT)
