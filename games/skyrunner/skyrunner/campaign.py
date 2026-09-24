"""Campaign: Palmetto Cay, 1979-1986.

Each chapter switches on one or two new systems for both sides and sets a few
objectives. The complexity ramp is the point: by 1982 you're juggling ferry
fuel, a co-pilot, a boat and informants, but you met each of them alone first.
See docs/DESIGN.md section 6 for the full storyline, including chapters 5-8.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

from .events import Event
from .jobs import Job, airdrop_job, new_id
from .loadout import Item, ferry_tank
from .maritime import random_drop_point
from .world import AIRFIELD_BY_CODE, HALF


@dataclass
class Objective:
    key: str
    text: str
    target: float = 1.0


@dataclass
class Chapter:
    num: int
    year: int
    title: str
    briefing: str
    runner: set[str]
    law: set[str]
    objectives: list[Objective]
    stock: dict[str, int] = field(default_factory=lambda: {"heli": 1, "interceptor": 0, "cutter": 0})
    setup: Callable | None = None
    playable: bool = True


def _manny_job(sess) -> None:
    here = AIRFIELD_BY_CODE[sess.location or "HAR"]
    jid = new_id()
    items = [Item(new_id(), "'Coffee' sacks", "cargo", 90.0, jid, hot=True),
             Item(new_id(), "'Coffee' sacks", "cargo", 90.0, jid, hot=True)]
    dest = "QRY" if here.code != "QRY" else "COV"
    job = Job(jid, f"Manny's coffee -> {AIRFIELD_BY_CODE[dest].name}", "contraband", here.code, dest, items, 4500,
              notes="Stay under the radar floor. Transponder off means primary-only - and suspicious if they see you.")
    sess.boards.setdefault(here.code, []).insert(0, job)


def _kickers_setup(sess) -> None:
    sess.set_copilot("ai")
    here = AIRFIELD_BY_CODE[sess.location or "HAR"]
    drop = random_drop_point(sess.world, sess.rng, near=sess.maritime.cove)
    sess.boards.setdefault(here.code, []).insert(0, airdrop_job(here, drop, sess.rng, bales=4))
    sess.say("Rosa is in the right seat: she loads, kicks and pumps. [K] kick, [O] call the boat.")


def _long_legs_setup(sess) -> None:
    """Start offshore to the south with a full ferry tank and bales already aboard."""
    sess.active_jobs.clear()
    sess.set_copilot("ai")
    lo = sess.loadout
    for iid in list(lo.items):
        lo.remove_item(iid)
    tank = ferry_tank(new_id(), lo.ferry_capacity())
    tank.set_fuel(tank.fuel_cap_lb)
    lo.add(tank)
    drop = random_drop_point(sess.world, sess.rng, near=sess.maritime.cove)
    job = airdrop_job(AIRFIELD_BY_CODE["COV"], drop, sess.rng, bales=4)
    job.origin = "SOUTH"
    job.accepted_at = sess.time
    sess.active_jobs.append(job)
    for it in job.items:
        lo.add(it)
    lo.auto_balance()
    lo.pending.clear()
    lo.fuel_lb = lo.mass.fuel_capacity_lb * 0.35
    boat = sess.maritime.new_gofast(drop, job.id)
    job.boat_id = boat.id
    sess.spawn_airborne(drop[0] * 0.3, -HALF + 600, 0.0, 250, 100)
    sess.say("Long Legs: 35% in the wings, the rest in the bladder. Pump it [V] before the engine quits.")


CHAPTERS: list[Chapter] = [
    Chapter(1, 1979, "Mail Run",
            "Palmetto Cay, 1979. The bank owns half your Cessna and Rosa's mail contract barely\n"
            "covers the fuel. Fly charters and freight, learn to balance a load, and prove you\n"
            "can get into Eagle's Nest - the mesa strip nobody else will touch.",
            runner=set(), law=set(),
            objectives=[Objective("earn_legal", "Earn $5,000 from legal work", 5000),
                        Objective("land_EGL", "Land at Eagle's Nest")]),
    Chapter(2, 1980, "A Favor for Manny",
            "Manny Arce sells boats at Smuggler's Cove and pays cash. He needs two sacks of\n"
            "'coffee' moved to the Old Quarry, quietly. Harbor and Valley radars can't see you\n"
            "below their clutter floor - the radar detector tells you when they're painting you.",
            runner={"contraband", "detector"}, law=set(),
            objectives=[Objective("hot_clean", "Deliver a hot load without ever being wanted")],
            setup=_manny_job),
    Chapter(3, 1981, "Kickers",
            "Landing with the goods is for amateurs. Manny's boat, the Lady Luck, will wait off\n"
            "the coast. Rosa rides along to push bales out of the door. Calling the boat on the\n"
            "radio helps it find you - and helps anyone listening find you too.",
            runner={"contraband", "detector", "airdrop", "copilot", "scanner"}, law={"interceptors", "rivals"},
            objectives=[Objective("kicked", "Kick 4 bales", 4), Objective("to_cove", "Get 3 bales to the cove", 3)],
            stock={"heli": 1, "interceptor": 1, "cutter": 0}, setup=_kickers_setup),
    Chapter(4, 1982, "Long Legs",
            "The loads come from the south now, farther than the tanks can carry. A bladder in\n"
            "the cabin fixes that - if someone pumps it forward. The Coast Guard has a cutter at\n"
            "Harbor, and people talk: every hot job you take is a chance for an informant.",
            runner={"contraband", "detector", "airdrop", "copilot", "scanner", "ferry", "spotters"},
            law={"interceptors", "rivals", "cutters", "informants"},
            objectives=[Objective("to_cove", "Fly in from the south and get 3 bales to the cove", 3)],
            stock={"heli": 1, "interceptor": 2, "cutter": 1}, setup=_long_legs_setup),
    Chapter(5, 1983, "The Balloon", "The task force puts an aerostat radar over the coast.", set(), set(), [],
            playable=False),
    Chapter(6, 1984, "Blue Water", "Cutters, encrypted police radio and direction finding.", set(), set(), [],
            playable=False),
    Chapter(7, 1985, "The Leak", "Someone in the crew is talking.", set(), set(), [], playable=False),
    Chapter(8, 1986, "Last Run / Flip", "The biggest run of your life, or Agent Hart's deal.", set(), set(), [],
            playable=False),
]


class Campaign:
    def __init__(self, index: int = 0, progress: dict | None = None):
        self.index = index
        self.progress: dict[str, float] = dict(progress or {})
        self.sess = None
        self.hot_flight_clean = True
        self.completed_all = False
        self.show_briefing = True

    @property
    def chapter(self) -> Chapter:
        return CHAPTERS[self.index]

    def to_dict(self) -> dict:
        return {"index": self.index, "progress": self.progress}

    @classmethod
    def from_dict(cls, d: dict | None) -> "Campaign":
        d = d or {}
        return cls(int(d.get("index", 0)), d.get("progress"))

    # ------------------------------------------------------------ wiring
    def attach(self, sess) -> None:
        self.sess = sess
        sess.campaign = self
        sess.bus.subscribe("*", self._on_event)
        self.apply(sess, run_setup=not self.progress)

    def apply(self, sess, run_setup: bool = True) -> None:
        ch = self.chapter
        sess.features = set(ch.runner) | set(ch.law)
        sess.police.features = set(ch.law)
        sess.police.stock = dict(ch.stock)
        sess.radio.df_enabled = "df" in ch.law
        sess.gear |= {g for g in ("scanner", "detector") if g in ch.runner}  # issued with the chapter
        if "copilot" not in ch.runner and sess.copilot == "ai":
            sess.set_copilot(None)
        for code in list(sess.boards):
            sess.refresh_board(code)
        if run_setup and ch.setup:
            ch.setup(sess)
        self.show_briefing = True
        sess.say(f"CHAPTER {ch.num} ({ch.year}): {ch.title}")

    def objective_lines(self) -> list[str]:
        out = []
        for o in self.chapter.objectives:
            v = self.progress.get(o.key, 0.0)
            mark = "x" if v >= o.target else " "
            count = f" ({int(v)}/{int(o.target)})" if o.target > 1 and o.key != "earn_legal" else ""
            if o.key == "earn_legal":
                count = f" (${int(v):,}/${int(o.target):,})"
            out.append(f"[{mark}] {o.text}{count}")
        return out

    # ------------------------------------------------------------ progress
    def _bump(self, key: str, amount: float = 1.0) -> None:
        if any(o.key == key for o in self.chapter.objectives):
            self.progress[key] = self.progress.get(key, 0.0) + amount

    def _on_event(self, ev: Event) -> None:
        d = ev.data
        if ev.kind == "job_delivered":
            if not d.get("hot"):
                self._bump("earn_legal", d.get("pay", 0))
            elif self.hot_flight_clean:
                self._bump("hot_clean")
        elif ev.kind == "landed":
            self._bump(f"land_{d.get('code')}")
            self.hot_flight_clean = True
        elif ev.kind == "bale_kicked":
            self._bump("kicked")
        elif ev.kind == "bales_delivered":
            self._bump("to_cove", d.get("count", 0))

    def tick(self, sess) -> None:
        if sess.carrying_hot() and sess.police.wanted > 0:
            self.hot_flight_clean = False
        ch = self.chapter
        if not ch.objectives or self.completed_all:
            return
        if all(self.progress.get(o.key, 0.0) >= o.target for o in ch.objectives):
            sess.say(f"Chapter {ch.num} complete: {ch.title}!")
            nxt = self.index + 1
            if nxt < len(CHAPTERS) and CHAPTERS[nxt].playable:
                self.index = nxt
                self.progress = {}
                self.apply(sess)
            else:
                self.completed_all = True
                sess.say("That's the story so far - chapters 5-8 arrive in the next phase. Free play unlocked.")
                sess.features |= {"contraband", "airdrop", "copilot", "scanner", "detector", "ferry", "spotters"}
            sess.save()
