"""Tiny synchronous event bus.

Game systems emit facts ("bale_delivered", "busted", ...). The campaign
engine, scoring, network layer and HUD subscribe. Events carry the side(s)
allowed to hear about them, so the network layer can keep fog of war.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from typing import Callable


@dataclass
class Event:
    kind: str
    t: float
    data: dict = field(default_factory=dict)
    audience: tuple[str, ...] = ("runner", "law")  # sides that may see it
    text: str = ""


class EventBus:
    def __init__(self):
        self._subs: dict[str, list[Callable[[Event], None]]] = defaultdict(list)
        self.log: list[Event] = []

    def subscribe(self, kind: str, fn: Callable[[Event], None]) -> None:
        """kind '*' receives everything."""
        self._subs[kind].append(fn)

    def emit(self, kind: str, t: float, text: str = "", audience=("runner", "law"), **data) -> Event:
        ev = Event(kind, t, data, tuple(audience), text)
        self.log.append(ev)
        del self.log[:-400]
        for fn in list(self._subs.get(kind, [])) + list(self._subs.get("*", [])):
            fn(ev)
        return ev

    def since(self, t: float, side: str | None = None) -> list[Event]:
        return [e for e in self.log if e.t > t and (side is None or side in e.audience)]
