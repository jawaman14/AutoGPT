"""Job board generation."""
from __future__ import annotations

import itertools
import math
import random
from dataclasses import dataclass

from .aircraft import LB_PER_KG
from .loadout import Item
from .world import Airfield

_ids = itertools.count(1)


@dataclass
class Job:
    id: int
    title: str
    kind: str  # passenger | cargo | medical | contraband | fugitive
    origin: str
    dest: str
    items: list[Item]
    payout: int
    deadline_s: float | None = None  # sim seconds after acceptance
    accepted_at: float | None = None
    notes: str = ""
    comfort: bool = False  # passengers who hate steep banks / hard landings

    @property
    def hot(self) -> bool:
        return any(i.hot for i in self.items)

    @property
    def weight_lb(self) -> float:
        return sum(i.weight_lb for i in self.items)

    def time_left(self, now: float) -> float | None:
        if self.deadline_s is None or self.accepted_at is None:
            return None
        return self.deadline_s - (now - self.accepted_at)


def _item(label, kind, kg, job_id, **kw) -> Item:
    return Item(next(_ids), label, kind, round(kg * LB_PER_KG, 1), job_id, **kw)


def _dist_km(a: Airfield, b: Airfield) -> float:
    return math.hypot(a.x - b.x, a.y - b.y) / 1000


def _difficulty(dest: Airfield) -> float:
    """Pay multiplier for hard destinations: short, narrow, high or odd strips."""
    m = 1.0
    if dest.length < 300:
        m += 0.6
    elif dest.length < 500:
        m += 0.3
    if dest.setting in ("plateau", "pit"):
        m += 0.4
    return m


PASSENGER_NAMES = [
    "Hiker", "Surveyor", "Doctor", "Tourist", "Fisherman", "Geologist", "Photographer",
    "Ranger", "Honeymooner", "Mechanic", "Priest", "Journalist",
]
CARGO_TYPES = [
    ("Mail sacks", 12, 25, False),
    ("Tool crate", 30, 70, False),
    ("Fuel drum", 75, 90, False),
    ("Generator", 90, 140, False),
    ("Food supplies", 20, 45, False),
    ("Glass panels", 25, 60, True),
    ("Lab samples", 5, 15, True),
]
CONTRABAND = [
    ("Unmarked crate", 25, 60),
    ("'Coffee' sacks", 20, 40),
    ("Sealed case", 8, 20),
]


def generate_jobs(origin: Airfield, airfields: tuple[Airfield, ...], rng: random.Random, n: int = 6) -> list[Job]:
    jobs: list[Job] = []
    others = [a for a in airfields if a.code != origin.code]
    for _ in range(n):
        dest = rng.choice(others)
        jid = next(_ids)
        dist = _dist_km(origin, dest)
        diff = _difficulty(dest)
        roll = rng.random()
        shady_origin = origin.kind in ("shady", "bush")
        if shady_origin and roll < 0.35:
            name, lo, hi = rng.choice(CONTRABAND)
            count = rng.randint(1, 4)
            items = [_item(name, "cargo", rng.uniform(lo, hi), jid, hot=True) for _ in range(count)]
            w = sum(i.weight_lb for i in items)
            pay = int((900 + w * 9 + dist * 120) * diff)
            jobs.append(Job(jid, f"No questions asked -> {dest.name}", "contraband", origin.code,
                            dest.code, items, pay, notes="Radar will flag you. Police will chase."))
        elif shady_origin and roll < 0.45:
            kg = rng.uniform(65, 105)
            items = [_item("Nervous man", "passenger", kg, jid, hot=True),
                     _item("Duffel bag", "cargo", rng.uniform(15, 35), jid, hot=True)]
            pay = int((2500 + dist * 180) * diff)
            jobs.append(Job(jid, f"Fugitive extraction -> {dest.name}", "fugitive", origin.code,
                            dest.code, items, pay, notes="Wanted man. Police are already looking."))
        elif roll < 0.72:
            count = rng.randint(1, 3)
            items = []
            for k in range(count):
                items.append(_item(rng.choice(PASSENGER_NAMES), "passenger", rng.uniform(55, 110), jid))
                if rng.random() < 0.6:
                    items.append(_item("Luggage", "cargo", rng.uniform(8, 25), jid))
            comfort = rng.random() < 0.3
            pay = int((150 + 60 * count + dist * 22 * count) * diff * (1.4 if comfort else 1.0))
            title = f"{'VIP ' if comfort else ''}Charter x{count} -> {dest.name}"
            jobs.append(Job(jid, title, "passenger", origin.code, dest.code, items, pay,
                            comfort=comfort,
                            notes="Keep bank under 45 deg and land softly." if comfort else ""))
        elif roll < 0.85 and dest.kind == "bush":
            items = [_item("Medical kit", "cargo", rng.uniform(10, 30), jid, fragile=True)]
            deadline = 60 * max(4.0, dist * 0.55 + 2.5)
            pay = int((300 + dist * 30) * diff)
            jobs.append(Job(jid, f"URGENT medical -> {dest.name}", "medical", origin.code, dest.code,
                            items, pay, deadline_s=deadline, notes="Deadline. Fragile."))
        else:
            name, lo, hi, fragile = rng.choice(CARGO_TYPES)
            count = rng.randint(1, 4)
            items = [_item(name, "cargo", rng.uniform(lo, hi), jid, fragile=fragile) for _ in range(count)]
            w = sum(i.weight_lb for i in items)
            pay = int((120 + w * 1.6 + dist * w * 0.09) * diff * (1.3 if fragile else 1.0))
            jobs.append(Job(jid, f"{name} x{count} -> {dest.name}", "cargo", origin.code, dest.code,
                            items, pay, notes="Fragile." if fragile else ""))
    return jobs
