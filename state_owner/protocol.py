from __future__ import annotations

import json
import socket
from typing import Any, Mapping

MAX_REQUEST_BYTES = 1024 * 1024
MAX_RESPONSE_BYTES = 16 * 1024 * 1024


def encode_message(value: Mapping[str, Any], *, max_bytes: int) -> bytes:
    encoded = json.dumps(
        value,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode() + b"\n"
    if len(encoded) > max_bytes:
        raise ValueError("message exceeds maximum size")
    return encoded


def read_message(connection: socket.socket, *, max_bytes: int) -> dict[str, Any]:
    chunks: list[bytes] = []
    size = 0
    while True:
        remaining = max_bytes + 1 - size
        if remaining <= 0:
            raise ValueError("message exceeds maximum size")
        chunk = connection.recv(min(65536, remaining))
        if not chunk:
            break
        newline = chunk.find(b"\n")
        content = chunk if newline < 0 else chunk[:newline]
        chunks.append(content)
        size += len(content)
        if size > max_bytes:
            raise ValueError("message exceeds maximum size")
        if newline >= 0:
            break

    raw = b"".join(chunks)
    if not raw:
        raise ValueError("empty request")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("message must be a JSON object")
    return value
