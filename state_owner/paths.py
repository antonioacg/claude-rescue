from __future__ import annotations

import hashlib
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class StatePaths:
    """All durable, cache, and socket paths owned by the State Owner."""

    data_home: Path
    cache_home: Path

    @classmethod
    def from_environment(cls) -> "StatePaths":
        home = Path.home()
        data_home = Path(
            os.environ.get(
                "CLAUDE_RESCUE_DATA_HOME",
                os.environ.get("XDG_DATA_HOME", str(home / ".local" / "share"))
                + "/claude-rescue",
            )
        )
        cache_home = Path(
            os.environ.get(
                "CLAUDE_RESCUE_CACHE_HOME",
                os.environ.get("XDG_CACHE_HOME", str(home / ".cache")) + "/claude-rescue",
            )
        )
        return cls(data_home=data_home, cache_home=cache_home)

    @property
    def database(self) -> Path:
        return self.data_home / "state" / "state.db"

    @property
    def spool(self) -> Path:
        return self.data_home / "state" / "spool"

    @property
    def archive(self) -> Path:
        return Path(os.environ.get("CLAUDE_RESCUE_ARCHIVE_DIR", self.data_home / "archive"))

    @property
    def archive_spool(self) -> Path:
        return self.data_home / "state" / "archive-spool"

    @property
    def capture_spool(self) -> Path:
        return self.data_home / "state" / "capture-spool"

    @property
    def socket(self) -> Path:
        runtime_home = Path(os.environ.get("XDG_RUNTIME_DIR", self.cache_home))
        candidate = runtime_home / "claude-rescue-state.sock"
        # sockaddr_un.sun_path is only 104 bytes on macOS. A hashed path in the
        # user's temporary directory keeps custom/test data homes usable.
        if len(os.fsencode(candidate)) < 100:
            return candidate
        digest = hashlib.sha256(os.fsencode(self.cache_home)).hexdigest()[:12]
        return Path(tempfile.gettempdir()) / f"claude-rescue-{os.getuid()}-{digest}.sock"

    @property
    def lock(self) -> Path:
        return self.cache_home / "state-owner.lock"

    @property
    def log(self) -> Path:
        return self.cache_home / "state-owner.log"
