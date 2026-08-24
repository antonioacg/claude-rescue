from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Mapping

_LEADING_STATUS = re.compile(r"^[^\x20-\x7e]+ *")


@dataclass(frozen=True)
class PaneState:
    pane_id: str
    pane_spec: str
    pane_uuid: str
    window_id: str
    window_uuid: str
    window_name: str
    command: str
    raw_title: str
    unseen: str
    active: bool
    visible: bool
    cleaned_title: str

    @property
    def raw_key(self) -> tuple[str, str, str]:
        return self.window_name, self.command, self.raw_title

    def to_mapping(self) -> dict[str, object]:
        return {
            "pane_id": self.pane_id,
            "pane_spec": self.pane_spec,
            "pane_uuid": self.pane_uuid,
            "window_id": self.window_id,
            "window_uuid": self.window_uuid,
            "window_name": self.window_name,
            "command": self.command,
            "raw_title": self.raw_title,
            "unseen": self.unseen,
            "active": self.active,
            "visible": self.visible,
            "cleaned_title": self.cleaned_title,
        }

    @classmethod
    def from_mapping(cls, value: Mapping[str, object]) -> "PaneState":
        strings = (
            "pane_id",
            "pane_spec",
            "pane_uuid",
            "window_id",
            "window_uuid",
            "window_name",
            "command",
            "raw_title",
            "unseen",
            "cleaned_title",
        )
        if any(not isinstance(value.get(name), str) for name in strings):
            raise ValueError("invalid watcher pane state")
        active = value.get("active")
        visible = value.get("visible")
        if not isinstance(active, bool) or not isinstance(visible, bool):
            raise ValueError("invalid watcher pane visibility state")
        return cls(
            pane_id=str(value["pane_id"]),
            pane_spec=str(value["pane_spec"]),
            pane_uuid=str(value["pane_uuid"]),
            window_id=str(value["window_id"]),
            window_uuid=str(value["window_uuid"]),
            window_name=str(value["window_name"]),
            command=str(value["command"]),
            raw_title=str(value["raw_title"]),
            unseen=str(value["unseen"]),
            active=active,
            visible=visible,
            cleaned_title=str(value["cleaned_title"]),
        )


@dataclass(frozen=True)
class CaptureRequest:
    pane: PaneState
    reason: str
    floor_only: bool


@dataclass(frozen=True)
class WindowLabels:
    full: str
    short: str


@dataclass(frozen=True)
class TickPlan:
    created: tuple[PaneState, ...]
    titles: tuple[PaneState, ...]
    died: tuple[PaneState, ...]
    captures: tuple[CaptureRequest, ...]


def default_cleaned_title(
    window_name: str,
    command: str,
    pane_title: str,
    host_short: str,
) -> str:
    if window_name.startswith("[tmux]"):
        window_name = command

    custom = window_name if window_name != command else ""
    meaningful_title = bool(pane_title) and pane_title != host_short
    if command in {"nvim", "claude"}:
        if meaningful_title:
            sequence = (
                _LEADING_STATUS.sub("", pane_title) if command == "claude" else pane_title
            )
            base = f"{sequence} - {command}"
        else:
            base = command
    elif meaningful_title:
        base = f"{command} - {pane_title}"
    else:
        base = command

    return f"{custom}: {base}" if custom else base


def abbreviate_label(label: str) -> str:
    letters = (
        character
        for character in label
        if ("a" <= character <= "z" or "A" <= character <= "Z")
        and character not in "aeiou"
    )
    return "".join(letters)[:5]


def labels_by_window(panes: Mapping[str, PaneState]) -> dict[str, WindowLabels]:
    selected: dict[str, PaneState] = {}
    for pane in panes.values():
        if pane.window_id not in selected or pane.active:
            selected[pane.window_id] = pane
    return {
        window_id: WindowLabels(
            full=pane.cleaned_title,
            short=abbreviate_label(pane.cleaned_title),
        )
        for window_id, pane in selected.items()
    }


def plan_tick(
    previous: Mapping[str, PaneState],
    current: Mapping[str, PaneState],
    *,
    first_tick: bool,
    now: float,
    last_captured: Mapping[str, float],
    visible_floor_seconds: int,
    background_floor_seconds: int,
) -> TickPlan:
    created: list[PaneState] = []
    titles: list[PaneState] = []
    captures: list[CaptureRequest] = []

    for pane in current.values():
        prior = previous.get(pane.pane_id)
        request: CaptureRequest | None = None
        if prior is None:
            if not first_tick:
                created.append(pane)
            request = CaptureRequest(pane, "created", False)
        else:
            if pane.cleaned_title != prior.cleaned_title:
                titles.append(pane)
                request = CaptureRequest(pane, "title", False)
            elif pane.unseen != prior.unseen:
                request = CaptureRequest(pane, "activity", False)
            elif pane.active != prior.active:
                request = CaptureRequest(pane, "visibility", False)

        if request is None:
            floor = visible_floor_seconds if pane.visible else background_floor_seconds
            last = last_captured.get(pane.pane_spec)
            if last is None or now - last >= floor:
                request = CaptureRequest(pane, "floor", True)
        if request is not None:
            captures.append(request)

    died = tuple(pane for pane_id, pane in previous.items() if pane_id not in current)
    return TickPlan(tuple(created), tuple(titles), died, tuple(captures))
