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


def new_id() -> int:
    """Unique id shared by jobs and items (and ferry tanks)."""
    return next(_ids)


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
    drop_point: tuple[float, float] | None = None  # airdrop jobs: rendezvous at sea
    boat_id: str | None = None
    bales_total: int = 0
    bales_delivered: int = 0
    resolved: bool = False

    @property
    def is_airdrop(self) -> bool:
        return self.drop_point is not None

    def target_xy(self, airfields: dict) -> tuple[float, float]:
        if self.drop_point is not None:
            return self.drop_point
        af = airfields[self.dest]
        return af.x, af.y

    def dest_label(self) -> str:
        return "DROP" if self.drop_point is not None else self.dest

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


def airdrop_job(origin: Airfield, drop_point: tuple[float, float], rng: random.Random, bales: int | None = None) -> Job:
    jid = next(_ids)
    n = bales or rng.randint(3, 6)
    items = [_item("Bale", "cargo", rng.uniform(22, 32), jid, hot=True, droppable=True) for _ in range(n)]
    dist = math.hypot(drop_point[0] - origin.x, drop_point[1] - origin.y) / 1000
    pay = int(n * (700 + dist * 40))
    return Job(jid, f"Kick {n} bales to the boat", "airdrop", origin.code, "SEA", items, pay,
               notes="Fly to the rendezvous, kick the bales near the boat [K]. Paid per bale landed at the cove.",
               drop_point=drop_point, bales_total=n)


def generate_jobs(origin: Airfield, airfields: tuple[Airfield, ...], rng: random.Random, n: int = 6,
                  features: set[str] | None = None, drop_point_fn=None) -> list[Job]:
    features = features if features is not None else {"contraband", "airdrop"}
    jobs: list[Job] = []
    others = [a for a in airfields if a.code != origin.code]
    shady_origin = origin.kind in ("shady", "bush")
    if "airdrop" in features and drop_point_fn is not None and shady_origin:
        jobs.append(airdrop_job(origin, drop_point_fn(), rng))
    if "ferry" in features and origin.kind in ("hub", "regional"):
        dest = rng.choice([a for a in airfields if a.kind in ("shady", "bush")])
        jid = next(_ids)
        count = rng.randint(1, 3)
        items = [_item("Fuel drum", "cargo", rng.uniform(75, 90), jid) for _ in range(count)]
        w = sum(i.weight_lb for i in items)
        jobs.append(Job(jid, f"Fuel cache x{count} -> {dest.name}", "cargo", origin.code, dest.code, items,
                        int(150 + w * 0.8), notes="Stocks a fuel cache there for your own runs."))
    while len(jobs) < n:
        dest = rng.choice(others)
        jid = next(_ids)
        dist = _dist_km(origin, dest)
        diff = _difficulty(dest)
        roll = rng.random()
        if "contraband" not in features and roll < 0.45:
            roll = 0.45 + roll  # no hot work offered yet
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
