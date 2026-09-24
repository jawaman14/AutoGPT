"""The task force: radar picture, suspicion/wanted per target, air units,
cutters, tips, and the controller (AI or human) that ties it together.

Air units are kinematic point-masses with turn/climb/speed limits and a short
terrain look-ahead. They are *not* JSBSim aircraft: that keeps them cheap, and
the imperfect terrain avoidance is deliberate - drag them through a canyon and
they can fly into the wall.

Units never read the true position of a target they can't see. They chase
what they see, else the radar track, else fly to the last known position
and search there.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from .comms import RadioNet
from .fdm import KT
from .sensors import Detection, SensorNet, Signature
from .world import Airfield, World

UNIT_TYPES = {
    #            max kts, turn deg/s, climb m/s, look-ahead m, faction
    "heli":        (120, 14.0, 7.0, 500.0, "police"),
    "interceptor": (230, 9.0, 15.0, 900.0, "police"),
    "rival":       (170, 11.0, 9.0, 700.0, "rival"),
}
ENDURANCE_S = {"heli": 900.0, "interceptor": 1200.0, "rival": 1e9}  # then bingo fuel, back to base
CALLSIGNS = {"heli": "Hawk", "interceptor": "Falcon", "rival": "Rival", "cutter": "Cutter"}

BUST_RANGE_M = 350.0
RIVAL_RANGE_M = 250.0
SIGHT_RANGE_M = 4500.0
LANDING_BUST_RANGE_M = 2500.0
SWEEP_INTERVAL_S = 1.0
LAUNCH_DELAY_S = 6.0
ENCRYPTION_DELAY_S = 8.0

LAW_FEATURES = {"interceptors", "aerostat", "cutters", "encryption", "df", "informants", "rivals"}


def _wrap180(a: float) -> float:
    return (a + 180.0) % 360.0 - 180.0


def _z(obj) -> float:
    return obj.alt if hasattr(obj, "alt") else obj.z


@dataclass
class Pursuer:
    kind: str
    x: float
    y: float
    z: float
    heading: float
    home: tuple[float, float]
    speed: float = 0.0  # m/s
    state: str = "pursuit"  # pursuit | goto | search | return | crashed
    sees_player: bool = False
    crashed_timer: float = 0.0
    just_crashed: bool = False
    id: str = ""
    target_id: str | None = None
    goal: tuple[float, float] | None = None
    chatter_t: float = -1e9
    had_visual: bool = False
    fuel_s: float = -1.0  # seconds of flying left; set at launch

    @property
    def spec(self):
        return UNIT_TYPES[self.kind]

    @property
    def faction(self) -> str:
        return self.spec[4]

    def dist_to(self, s) -> float:
        return math.dist((self.x, self.y, self.z), (s.x, s.y, _z(s)))

    def update(self, dt: float, target, world: World, goal: tuple[float, float] | None = None) -> None:
        """target: something with x, y, alt|z, vx, vy to intercept (seen or tracked).
        goal: fly there and orbit when there's no target."""
        if self.state == "crashed":
            self.crashed_timer += dt
            return
        if self.fuel_s < 0:
            self.fuel_s = ENDURANCE_S[self.kind]
        self.fuel_s -= dt
        vmax_kts, turn, climb, look, _ = self.spec
        vmax = vmax_kts * KT
        orbit = False
        if target is not None and self.state != "return":
            d = math.hypot(target.x - self.x, target.y - self.y)
            lead = min(8.0, d / max(vmax, 1.0))
            tx, ty = target.x + target.vx * lead, target.y + target.vy * lead
            tz = _z(target)
            # close to ~150 m formation, then match speed
            tspeed = math.hypot(target.vx, target.vy)
            want_speed = max(35.0, min(vmax, tspeed + (d - 150.0) * 0.15))
        elif goal is not None and self.state != "return":
            tx, ty = goal
            tz = world.ground(tx, ty) + 350
            want_speed = vmax * 0.75
            orbit = math.hypot(tx - self.x, ty - self.y) < 700
        else:
            tx, ty = self.home
            tz = world.ground(tx, ty) + 300
            want_speed = vmax * 0.7
        if orbit:
            self.heading = (self.heading + turn * 0.6 * dt) % 360
        else:
            desired = math.degrees(math.atan2(tx - self.x, ty - self.y))
            err = _wrap180(desired - self.heading)
            self.heading = (self.heading + max(-turn * dt, min(turn * dt, err))) % 360
        self.speed += max(-6 * dt, min(6 * dt, want_speed - self.speed))
        # terrain look-ahead (only straight ahead: canyons can still catch them)
        h = math.radians(self.heading)
        ax, ay = self.x + math.sin(h) * look, self.y + math.cos(h) * look
        floor = max(world.ground(ax, ay), world.ground(self.x, self.y)) + 60
        tz = max(tz, floor)
        dz = max(-climb * dt, min(climb * dt, tz - self.z))
        self.x += math.sin(h) * self.speed * dt
        self.y += math.cos(h) * self.speed * dt
        self.z += dz
        if self.z < world.ground(self.x, self.y) + 2 or world.tree_hit(self.x, self.y, self.z, 4):
            self.state = "crashed"
            self.just_crashed = True
            self.z = world.ground(self.x, self.y)


@dataclass
class Target:
    """A thing the task force might chase. `hot` is ground truth, used only for
    game outcomes (a bust on a clean aircraft finds nothing)."""
    sig: Signature
    hot: bool = False
    value: int = 0
    label: str = ""


@dataclass
class Case:
    target_id: str
    suspicion: float = 0.0
    wanted: int = 0
    bust_meter: float = 0.0
    rival_meter: float = 0.0
    seen_time: float = 0.0
    unseen_time: float = 0.0
    last_known: tuple[float, float, float] | None = None  # x, y, t
    detected_by: str | None = None
    identified_t: float = -1e9  # last time we saw its transponder
    squawk: str = ""
    tipped: bool = False
    drop_alerted: bool = False


@dataclass
class Tip:
    t: float
    x: float
    y: float
    radius: float
    text: str
    squawk: str = ""


@dataclass
class PoliceSystem:
    world: World
    rng: random.Random = field(default_factory=random.Random)
    radio: RadioNet | None = None
    controller: str = "ai"  # ai | human
    features: set[str] = field(default_factory=lambda: {"interceptors", "rivals"})
    stock: dict[str, int] = field(default_factory=lambda: {"heli": 1, "interceptor": 2, "cutter": 1})
    units: list[Pursuer] = field(default_factory=list)
    cases: dict[str, Case] = field(default_factory=dict)
    tips: list[Tip] = field(default_factory=list)
    events: list[str] = field(default_factory=list)  # runner-facing messages
    law_events: list[str] = field(default_factory=list)  # controller-facing messages
    score: dict[str, int] = field(default_factory=lambda: {"busts": 0, "clean_stops": 0, "bales_seized": 0, "boats_seized": 0})

    def __post_init__(self):
        self.sensors = SensorNet(self.world, random.Random(self.rng.random()))
        self.radio = self.radio or RadioNet(random.Random(self.rng.random()))
        self.detections: dict[str, Detection] = {}
        self._launches: list[tuple[float, str, str, str | None, tuple | None]] = []
        self._sweep_acc = SWEEP_INTERVAL_S
        self._serial = 0
        self._rival_spawned: set[str] = set()
        self._flight_time: dict[str, float] = {}
        self.now = 0.0
        self.aerostat_ready_t: float | None = None
        self._alias: dict[str, str] = {}
        self._unalias: dict[str, str] = {}

    # ---------------------------------------------------- anonymous track numbers
    def alias(self, target_id: str | None) -> str | None:
        """What the desk calls a contact: 'T3', never the internal id."""
        if target_id is None:
            return None
        if target_id not in self._alias:
            a = f"T{len(self._alias) + 1}"
            self._alias[target_id], self._unalias[a] = a, target_id
        return self._alias[target_id]

    def resolve(self, name: str | None) -> str | None:
        return self._unalias.get(name, name) if name else name

    # ---------------------------------------------------- runner-facing compat
    def case(self, tid: str = "runner") -> Case:
        if tid not in self.cases:
            self.cases[tid] = Case(tid)
        return self.cases[tid]

    @property
    def suspicion(self) -> float:
        return self.case().suspicion

    @suspicion.setter
    def suspicion(self, v: float) -> None:
        self.case().suspicion = v

    @property
    def wanted(self) -> int:
        return self.case().wanted

    @wanted.setter
    def wanted(self, v: int) -> None:
        self.case().wanted = v

    @property
    def bust_meter(self) -> float:
        return self.case().bust_meter

    @property
    def rival_meter(self) -> float:
        return self.case().rival_meter

    @property
    def detected_by(self) -> str | None:
        return self.case().detected_by

    def detector(self, tid: str = "runner") -> str:
        d = self.detections.get(tid)
        return d.detector_level if d else ""

    def reset(self, keep_wanted: bool = False, tid: str = "runner") -> None:
        c = self.case(tid)
        wanted = c.wanted
        self.cases[tid] = Case(tid, wanted=wanted if keep_wanted else 0, tipped=c.tipped and keep_wanted)
        for u in self.units:
            if u.target_id == tid and u.faction == "rival":
                u.state = "return"
        if not keep_wanted:
            for u in self.units:
                if u.target_id == tid:
                    u.target_id = None
                    u.state = "return"
        self._rival_spawned.discard(tid)
        self._flight_time[tid] = 0.0

    # ---------------------------------------------------- radio
    def _say(self, sender: str, text: str, pos=None) -> None:
        self.radio.transmit(self.now, "police", sender, text, pos)
        self.law_events.append(f"{sender}: {text}")

    # ---------------------------------------------------- resources / commands
    def police_bases(self) -> list[Airfield]:
        return [a for a in self.world.airfields if a.police]

    def launch(self, kind: str, base_code: str | None = None, target_id: str | None = None,
               goal: tuple[float, float] | None = None, near: tuple[float, float] | None = None) -> str | None:
        """Queue a unit launch. Returns an error string or None."""
        if kind == "interceptor" and "interceptors" not in self.features:
            return "No interceptors assigned to this task force yet."
        if kind == "cutter":
            return "Cutters are launched by the maritime desk."  # handled by Session/maritime
        if self.stock.get(kind, 0) <= 0:
            return f"No {kind} available."
        bases = self.police_bases()
        if base_code:
            base = next((b for b in bases if b.code == base_code), None)
            if base is None:
                return f"{base_code} is not a police base."
        else:
            ref = near or goal or (0.0, 0.0)
            base = min(bases, key=lambda a: (a.x - ref[0]) ** 2 + (a.y - ref[1]) ** 2)
        self.stock[kind] -= 1
        delay = LAUNCH_DELAY_S + (ENCRYPTION_DELAY_S if self.radio.encrypted else 0.0)
        self._launches.append((self.now + delay, kind, base.code, target_id, goal))
        return None

    def _spawn_now(self, kind: str, base_code: str, target_id, goal) -> Pursuer:
        base = next(a for a in self.world.airfields if a.code == base_code)
        self._serial += 1
        u = Pursuer(kind, base.x, base.y, self.world.airfield_elev(base) + 60, base.heading, (base.x, base.y),
                    speed=UNIT_TYPES[kind][0] * KT * 0.5, id=f"{CALLSIGNS[kind]}-{self._serial}",
                    target_id=target_id, goal=goal, state="pursuit" if target_id else "goto")
        self.units.append(u)
        where = f"toward {self.alias(target_id)}" if target_id else "to assigned area"
        self._say(u.id, f"airborne from {base.name}, vectoring {where}", (u.x, u.y))
        return u

    def spawn_rival(self, near: tuple[float, float], target_id: str) -> Pursuer:
        ang = self.rng.uniform(0, 2 * math.pi)
        x, y = near[0] + 5000 * math.cos(ang), near[1] + 5000 * math.sin(ang)
        self._serial += 1
        u = Pursuer("rival", x, y, self.world.ground(x, y) + 250, 0.0, (x, y), speed=UNIT_TYPES["rival"][0] * KT * 0.6,
                    id=f"Rival-{self._serial}", target_id=target_id)
        self.units.append(u)
        return u

    def dispatch(self, unit_id: str, target_id: str | None = None, point: tuple[float, float] | None = None) -> str | None:
        u = next((u for u in self.units if u.id == unit_id and u.state != "crashed"), None)
        if u is None:
            return f"No unit {unit_id}."
        u.target_id, u.goal = target_id, point
        u.state = "pursuit" if target_id else "goto"
        self._say(u.id, f"copies, {'intercepting ' + self.alias(target_id) if target_id else 'proceeding to area'}", (u.x, u.y))
        return None

    def recall(self, unit_id: str) -> str | None:
        u = next((u for u in self.units if u.id == unit_id), None)
        if u is None:
            return f"No unit {unit_id}."
        u.state, u.target_id, u.goal = "return", None, None
        self._say(u.id, "RTB", (u.x, u.y))
        return None

    def set_encryption(self, on: bool) -> str | None:
        if on and "encryption" not in self.features:
            return "Encryption not budgeted yet."
        self.radio.encrypted = on
        self.law_events.append(f"Radio encryption {'ON (slower dispatch)' if on else 'OFF'}")
        return None

    def set_aerostat(self, on: bool) -> str | None:
        if "aerostat" not in self.features:
            return "No aerostat on station."
        site = self.sensors.site("AER")
        if on:
            self.aerostat_ready_t = self.now + 60.0
            self.law_events.append("Aerostat going up - radar live in 60 s")
        else:
            site.active = False
            self.aerostat_ready_t = None
        return None

    def add_tip(self, x: float, y: float, radius: float, text: str, squawk: str = "", target_id: str | None = None) -> None:
        if "informants" not in self.features:
            return
        self.tips.append(Tip(self.now, x, y, radius, text, squawk))
        del self.tips[:-12]
        self.law_events.append(f"TIP: {text}")
        if target_id:
            self.case(target_id).tipped = True
            self.case(target_id).suspicion = max(self.case(target_id).suspicion, 40.0)
        if self.controller == "ai" and self.stock.get("heli", 0) > 0:
            self.launch("heli", goal=(x, y))

    # ---------------------------------------------------- AI controller
    def _ai_escalate(self, case: Case, level: int, sig: Signature) -> None:
        level = max(0, min(3, level))
        if level > case.wanted:
            self.events.append(f"WANTED LEVEL {level}")
            need = {1: ["heli"], 2: ["heli", "interceptor"], 3: ["heli", "interceptor", "interceptor"]}[level]
            have = [u.kind for u in self.units if u.faction == "police" and u.target_id == case.target_id
                    and u.state not in ("crashed", "return")]
            have += [k for _, k, _, tid, _ in self._launches if tid == case.target_id]
            for k in need:
                if k in have:
                    have.remove(k)
                    continue
                # re-task an idle unit first, then launch
                idle = next((u for u in self.units if u.kind == k and u.faction == "police"
                             and u.target_id is None and u.state in ("goto", "return", "search")), None)
                if idle:
                    idle.target_id, idle.state, idle.goal = case.target_id, "pursuit", None
                elif not (k == "interceptor" and "interceptors" not in self.features):
                    self.launch(k, target_id=case.target_id, near=(sig.x, sig.y))
        elif level < case.wanted:
            self.events.append("Wanted level down" if level else "You lost them. Heat is off.")
            if level == 0:
                for u in self.units:
                    if u.faction == "police" and u.target_id == case.target_id:
                        u.state, u.target_id = "return", None
        case.wanted = level

    # ---------------------------------------------------- main tick
    def tick(self, dt: float, now: float, targets: list[Target]) -> dict[str, str]:
        """Advance the task force. Returns {target_id: "busted" | "clean" | "hijacked"}."""
        self.now = now
        outcomes: dict[str, str] = {}
        by_id = {t.sig.id: t for t in targets}

        # aerostat winch
        if self.aerostat_ready_t is not None and now >= self.aerostat_ready_t:
            self.sensors.site("AER").active = True
            self.aerostat_ready_t = None
            self.law_events.append("Aerostat radar on line")

        # launches
        for item in [x for x in self._launches if x[0] <= now]:
            self._launches.remove(item)
            _, kind, base, tid, goal = item
            self._spawn_now(kind, base, tid, goal)

        # radar sweep (1 Hz, like a rotating antenna)
        self._sweep_acc += dt
        if self._sweep_acc >= SWEEP_INTERVAL_S:
            self._sweep_acc = 0.0
            self.detections = self.sensors.sweep([t.sig for t in targets], now)
            for t in targets:
                self._classify(t, SWEEP_INTERVAL_S)

        # units
        seen_by: dict[str, list[Pursuer]] = {}
        for u in self.units:
            tgt = by_id.get(u.target_id) if u.target_id else None
            chase, goal = None, u.goal
            if tgt is not None:
                if self._can_see(u, tgt.sig):
                    chase = tgt.sig
                else:
                    tr = self.sensors.tracks.get(tgt.sig.id)
                    if tr is not None and tr.age(now) < 3.0:
                        chase = tr
                    else:
                        c = self.case(tgt.sig.id)
                        goal = c.last_known[:2] if c.last_known else goal
            elif u.target_id and u.target_id not in by_id and u.faction == "police":
                # target landed or left: search where it was last seen
                c = self.cases.get(u.target_id)
                goal = c.last_known[:2] if c and c.last_known else None
                if goal is None:
                    u.state = "return"
            if u.faction == "police" and 0 <= u.fuel_s < 1.0 and u.state != "return":
                u.state, u.target_id, u.goal = "return", None, None
                self._say(u.id, "bingo fuel, RTB", (u.x, u.y))
            if u.state == "return":
                chase, goal = None, None
            was_crashed = u.state == "crashed"
            u.update(dt, chase, self.world, goal=goal)
            if u.state == "crashed":
                if u.just_crashed and not was_crashed:
                    u.just_crashed = False
                    msg = f"The {u.faction} {u.kind} hit the terrain!"
                    self.events.append(msg)
                    self.law_events.append(f"{u.id} DOWN - crashed into terrain")
                continue
            # visual acquisition of anything suspicious
            u.sees_player = False
            for t in targets:
                if not self._can_see(u, t.sig):
                    continue
                c = self.case(t.sig.id)
                if u.faction == "rival":
                    if u.target_id == t.sig.id:
                        u.sees_player = True
                        seen_by.setdefault("rival:" + t.sig.id, []).append(u)
                    continue
                if u.target_id == t.sig.id or (u.target_id is None and (c.wanted or c.suspicion >= 50)):
                    u.target_id, u.state = t.sig.id, "pursuit"
                    u.sees_player = True
                    seen_by.setdefault(t.sig.id, []).append(u)
                    c.last_known = (t.sig.x, t.sig.y, now)
                    if not u.had_visual and now - u.chatter_t > 12:
                        u.chatter_t = now
                        hdg = math.degrees(math.atan2(t.sig.vx, t.sig.vy)) % 360
                        self._say(u.id, f"tally on {self.alias(t.sig.id)}, heading {hdg:03.0f}, "
                                        f"{'low' if t.sig.agl < 150 else 'medium'}", (u.x, u.y))
            if u.had_visual and not u.sees_player and u.faction == "police" and now - u.chatter_t > 12:
                u.chatter_t = now
                self._say(u.id, "lost visual, searching last known", (u.x, u.y))
            u.had_visual = u.sees_player
        self.units = [u for u in self.units if not (u.state == "crashed" and u.crashed_timer > 20)]
        returned = [u for u in self.units if u.state == "return" and math.hypot(u.x - u.home[0], u.y - u.home[1]) < 300]
        for u in returned:
            if u.faction == "police":
                self.stock[u.kind] = self.stock.get(u.kind, 0) + 1
        self.units = [u for u in self.units if u not in returned]

        # per-target bookkeeping
        for t in targets:
            tid = t.sig.id
            c = self.case(tid)
            self._flight_time[tid] = self._flight_time.get(tid, 0.0) + dt
            seen = bool(seen_by.get(tid)) or bool(c.detected_by)
            if c.wanted:
                if seen:
                    c.seen_time += dt
                    c.unseen_time = 0.0
                    if c.seen_time > 60 and c.wanted < 3 and self.controller == "ai":
                        c.seen_time = 0.0
                        self._ai_escalate(c, c.wanted + 1, t.sig)
                else:
                    c.unseen_time += dt
                    if c.unseen_time > 15 + 12 * c.wanted:
                        c.unseen_time = c.seen_time = 0.0
                        if self.controller == "ai":
                            self._ai_escalate(c, c.wanted - 1, t.sig)
                        else:
                            c.wanted -= 1
                        if c.wanted == 0:
                            c.suspicion = 0.0
            close = any(u.dist_to(t.sig) < BUST_RANGE_M for u in seen_by.get(tid, []))
            c.bust_meter = min(100.0, c.bust_meter + 22 * dt) if close else max(0.0, c.bust_meter - 12 * dt)
            if c.bust_meter >= 100:
                c.bust_meter = 0.0
                outcomes[tid] = "busted" if t.hot else "clean"
                self._close_case(tid, t.hot)
                continue
            # rivals
            if ("rivals" in self.features and t.hot and t.value > 2000 and tid not in self._rival_spawned
                    and self._flight_time[tid] > 45 and tid == "runner"):
                self._rival_spawned.add(tid)
                if self.rng.random() < 0.6:
                    self.spawn_rival((t.sig.x, t.sig.y), tid)
                    self.events.append("Rival smugglers inbound! Don't let them close in.")
            rclose = any(u.dist_to(t.sig) < RIVAL_RANGE_M for u in seen_by.get("rival:" + tid, []))
            c.rival_meter = min(100.0, c.rival_meter + 14 * dt) if rclose else max(0.0, c.rival_meter - 10 * dt)
            if c.rival_meter >= 100:
                c.rival_meter = 0.0
                for u in self.units:
                    if u.faction == "rival" and u.target_id == tid:
                        u.state = "return"
                outcomes[tid] = "hijacked"
        return outcomes

    def _close_case(self, tid: str, hot: bool) -> None:
        if hot:
            self.score["busts"] += 1
            self.law_events.append(f"BUST: {self.alias(tid)} forced down, contraband found")
        else:
            self.score["clean_stops"] += 1
            self.law_events.append(f"{self.alias(tid)} forced down - search found nothing")
        for u in self.units:
            if u.target_id == tid:
                u.target_id, u.state = None, "return"
        self.cases[tid] = Case(tid)

    def _can_see(self, u: Pursuer, sig: Signature) -> bool:
        if u.state == "crashed":
            return False
        if u.dist_to(sig) > SIGHT_RANGE_M:
            return False
        return self.world.line_of_sight((u.x, u.y, u.z), (sig.x, sig.y, sig.z), step=100)

    def _classify(self, t: Target, dt: float) -> None:
        sig, c = t.sig, self.case(t.sig.id)
        det = self.detections.get(sig.id)
        site_code = det.detected_by[0] if det and det.detected_by else None
        c.detected_by = site_code
        if site_code:
            c.last_known = (sig.x, sig.y, self.now)
            if sig.transponder:
                c.identified_t, c.squawk = self.now, sig.squawk
        # squawk lost while being tracked: the classic tell
        if site_code and not sig.transponder and 0 < self.now - c.identified_t < 20 and c.squawk:
            c.suspicion = min(100.0, c.suspicion + 50)
            self._say("Center", f"squawk {c.squawk} lost at {site_code}, primary only", None)
            c.squawk = ""
        if c.wanted:
            return
        if site_code:
            site = self.sensors.site(site_code)
            d = math.hypot(sig.x - site.x, sig.y - site.y)
            rate = 8 + 25 * (1 - d / site.range_m)
            if sig.transponder and not c.tipped:
                rate = 0.0  # identified, filed traffic
            elif sig.transponder:
                rate *= 0.5
            # low and slow over water looks like an airdrop
            if (self.world.is_water(sig.x, sig.y) and sig.speed_kts < 110 and sig.agl < 350):
                rate += 6
                if not c.drop_alerted:
                    c.drop_alerted = True
                    self.law_events.append(f"ALERT: possible airdrop pattern near {sig.x / 1000:.1f},{sig.y / 1000:.1f} km")
                    self.tips.append(Tip(self.now, sig.x, sig.y, 1500, "possible airdrop"))
            c.suspicion += dt * rate
            if c.suspicion >= 100:
                c.suspicion = 100
                self.events.append(f"{site.name} has you. Police dispatched!")
                self.law_events.append(f"Track {self.alias(sig.id)} flagged suspicious by {site.name}")
                if self.controller == "ai":
                    self._ai_escalate(c, 1, sig)
                else:
                    c.wanted = 1
        else:
            c.suspicion = max(0.0, c.suspicion - 5 * dt)

    # ---------------------------------------------------- landing
    def landing_check(self, s, field_: Airfield, carrying_hot: bool, tid: str = "runner") -> bool:
        """Called once when the player comes to a stop. True -> police grab you."""
        c = self.case(tid)
        for u in self.units:
            if u.faction == "police" and u.target_id == tid and u.state != "crashed" and u.dist_to(s) < LANDING_BUST_RANGE_M:
                return True
        if field_.police and c.wanted > 0:
            return True
        if field_.police and carrying_hot and self.rng.random() < 0.35:
            self.events.append("Customs inspection!")
            return True
        return False

    def nearest_threat(self, s) -> tuple[Pursuer, float] | None:
        live = [u for u in self.units if u.state not in ("crashed", "return")]
        if not live:
            return None
        u = min(live, key=lambda u: u.dist_to(s))
        return u, u.dist_to(s)
