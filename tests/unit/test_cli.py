from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from offroad_batman.jobs.array_io import decode_array, encode_array
from offroad_batman.jobs.cli import _read_metadata, _write_result, build_parser


def test_cli_defaults_match_fixed_node_roles() -> None:
    parser = build_parser()

    receive = parser.parse_args(["receive"])
    submit = parser.parse_args(
        ["submit", "--input", "input.npy", "--metadata", "metadata.json"]
    )

    assert receive.host == "::"
    assert receive.port == 8080
    assert submit.receiver == "http://olo.mesh:8080"
    assert submit.callback_url == "http://ragnarhorn.mesh:8080/v1/callbacks"


def test_cli_metadata_and_result_file_helpers(tmp_path: Path) -> None:
    metadata_path = tmp_path / "metadata.json"
    metadata_path.write_text(json.dumps({"operation": "test"}), encoding="utf-8")
    assert _read_metadata(metadata_path) == {"operation": "test"}

    result_path = tmp_path / "output" / "result.npy"
    encoded = encode_array(np.arange(3)).data
    _write_result(result_path, encoded)
    np.testing.assert_array_equal(decode_array(result_path.read_bytes()), np.arange(3))
