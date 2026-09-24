"""Airdrops, go-fast boats and Coast Guard cutters.

The 1980s pattern: an aircraft never lands with the load. Kickers push bales
out over open water, a go-fast boat fishes them out and runs for a cove, and
the task force tries to catch the boat or seize the floating bales.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from .fdm import KT
from .world import AIRFIELD_BY_CODE, HALF, World

G = 9.81
BALE_TERMINAL_V = 35.0
BALE_K = G / BALE_TERMINAL_V ** 2
CURRENT = (0.25, 0.08)  # m/s surface drift
PICKUP_RADIUS_M = 40.0
PICKUP_TIME_S = 5.0
SEIZE_RADIUS_M = 120.0
SEIZE_TIME_S = 6.0
SURFACE_RADAR_M = 7000.0
BOAT_TYPES = {"gofast": 45.0, "cutter": 32.0}  # max kts


def _wrap180(a: float) -> float:
    return (a + 180.0) % 360.0 - 180.0


def is_sea(world: World, x: float, y: float, depth: float = -1.5) -> bool:
    return world.height(x, y) < depth


def cove_point(world: World) -> tuple[float, float]:
    """Deep-ish water nearest Smuggler's Cove: where boats hand off the load."""
    cov = AIRFIELD_BY_CODE["COV"]
    for r in range(300, 5000, 100):
        for k in range(36):
            a = 2 * math.pi * k / 36
            x, y = cov.x + r * math.cos(a), cov.y + r * math.sin(a)
            if is_sea(world, x, y, -4.0):
                return x, y
    return cov.x + 2000, cov.y


def random_drop_point(world: World, rng: random.Random, near: tuple[float, float] | None = None) -> tuple[float, float]:
    """Open water 1.5-8 km off the coast, inside the map."""
    for _ in range(4000):
        if near:
            a = rng.uniform(0, 2 * math.pi)
            r = rng.uniform(3000, 12000)
            x, y = near[0] + r * math.cos(a), near[1] + r * math.sin(a)
        else:
            x, y = rng.uniform(-HALF + 1500, HALF - 1500), rng.uniform(-HALF + 1500, HALF - 1500)
        if abs(x) > HALF - 1500 or abs(y) > HALF - 1500 or not is_sea(world, x, y, -20.0):
            continue
        # not too far from land (boats have to reach it)
        if any(not is_sea(world, x + 8000 * math.cos(b), y + 8000 * math.sin(b)) for b in
               (0, math.pi / 2, math.pi, 3 * math.pi / 2)):
            return x, y
    return 0.0, -HALF + 2500


@dataclass
class Bale:
    id: int
    job_id: int
    x: float
    y: float
    z: float
    vx: float
    vy: float
    vz: float = 0.0
    weight_lb: float = 60.0
    state: str = "falling"  # falling | floating | landed | collected | seized | sunk
    t_state: float = 0.0

    def update(self, dt: float, world: World) -> str | None:
        """Returns the new state on a transition."""
        self.t_state += dt
        if self.state == "falling":
            n = max(1, int(dt / 0.02))
            h = dt / n
            for _ in range(n):
                v = math.sqrt(self.vx ** 2 + self.vy ** 2 + self.vz ** 2)
                self.vx -= BALE_K * v * self.vx * h
                self.vy -= BALE_K * v * self.vy * h
                self.vz += (-G - BALE_K * v * self.vz) * h
                self.x += self.vx * h
                self.y += self.vy * h
                self.z += self.vz * h
                surface = world.ground(self.x, self.y)
                if self.z <= surface:
                    self.z = surface
                    self.vx = self.vy = self.vz = 0.0
                    self.state = "floating" if world.is_water(self.x, self.y) else "landed"
                    self.t_state = 0.0
                    return self.state
        elif self.state == "floating":
            self.x += CURRENT[0] * dt
            self.y += CURRENT[1] * dt
            if self.t_state > 1200:  # waterlogged, gone
                self.state = "sunk"
                return self.state
        return None


@dataclass
class Boat:
    id: str
    kind: str  # gofast | cutter
    x: float
    y: float
    heading: float = 0.0
    speed: float = 0.0  # m/s
    state: str = "standby"
    goal: tuple[float, float] | None = None
    home: tuple[float, float] = (0.0, 0.0)
    cargo: list[int] = field(default_factory=list)  # bale ids aboard
    job_id: int | None = None
    work_t: float = 0.0
    seize_meter: float = 0.0
    wait_t: float = 0.0
    target_id: str | None = None  # cutters: boat being chased

    @property
    def side(self) -> str:
        return "law" if self.kind == "cutter" else "runner"

    @property
    def max_speed(self) -> float:
        return BOAT_TYPES[self.kind] * KT

    def steer(self, dt: float, world: World, goal: tuple[float, float], speed_frac: float = 1.0) -> float:
        """Head for goal while keeping to water. Returns remaining distance."""
        gx, gy = goal
        dist = math.hypot(gx - self.x, gy - self.y)
        desired = math.degrees(math.atan2(gx - self.x, gy - self.y))
        best = None
        for off in (0, 20, -20, 40, -40, 60, -60, 90, -90, 120, -120, 150, -150, 180):
            h = math.radians(desired + off)
            ok = all(is_sea(world, self.x + math.sin(h) * r, self.y + math.cos(h) * r) for r in (60, 200, 400))
            if ok:
                best = desired + off
                break
        want = speed_frac * self.max_speed if dist > 30 else 0.0
        if best is None:  # boxed in: stop and turn around
            best, want = self.heading + 90, 2.0
        err = _wrap180(best - self.heading)
        self.heading = (self.heading + max(-25 * dt, min(25 * dt, err))) % 360
        self.speed += max(-4 * dt, min(3 * dt, want - self.speed))
        h = math.radians(self.heading)
        nx, ny = self.x + math.sin(h) * self.speed * dt, self.y + math.cos(h) * self.speed * dt
        if is_sea(world, nx, ny, -0.5):
            self.x, self.y = nx, ny
        else:
            self.speed = 0.0
        return dist

    @property
    def vx(self) -> float:
        return math.sin(math.radians(self.heading)) * self.speed

    @property
    def vy(self) -> float:
        return math.cos(math.radians(self.heading)) * self.speed


@dataclass
class Maritime:
    world: World
    rng: random.Random = field(default_factory=random.Random)
    boats: list[Boat] = field(default_factory=list)
    bales: list[Bale] = field(default_factory=list)
    events: list[tuple[str, dict]] = field(default_factory=list)

    def __post_init__(self):
        self.cove = cove_point(self.world)
        har = AIRFIELD_BY_CODE["HAR"]
        self.cg_station = next(
            (har.x + r * math.cos(a), har.y + r * math.sin(a))
            for r in range(300, 6000, 100)
            for a in [2 * math.pi * k / 24 for k in range(24)]
            if is_sea(self.world, har.x + r * math.cos(a), har.y + r * math.sin(a), -4.0)
        )
        self._serial = 0
        self._bale_serial = 0

    # ------------------------------------------------------------ spawning
    def new_gofast(self, rendezvous: tuple[float, float], job_id: int) -> Boat:
        self._serial += 1
        b = Boat(f"LadyLuck-{self._serial}", "gofast", *self.cove, home=self.cove, job_id=job_id,
                 goal=rendezvous, state="to_rendezvous")
        self.boats.append(b)
        return b

    def new_cutter(self, goal: tuple[float, float] | None = None) -> Boat:
        self._serial += 1
        b = Boat(f"Cutter-{self._serial}", "cutter", *self.cg_station, home=self.cg_station,
                 goal=goal, state="patrol" if goal else "standby")
        self.boats.append(b)
        return b

    def drop_bale(self, job_id: int, x, y, z, vx, vy, vz, weight_lb) -> Bale:
        self._bale_serial += 1
        b = Bale(self._bale_serial, job_id, x, y, z, vx, vy, vz, weight_lb)
        self.bales.append(b)
        return b

    def boat(self, boat_id: str) -> Boat | None:
        return next((b for b in self.boats if b.id == boat_id), None)

    def gofast_for(self, job_id: int) -> Boat | None:
        return next((b for b in self.boats if b.kind == "gofast" and b.job_id == job_id), None)

    # ------------------------------------------------------------ tick
    def update(self, dt: float, law_goals: list[tuple[float, float]] | None = None) -> None:
        for bale in self.bales:
            new = bale.update(dt, self.world)
            if new == "landed":
                self.events.append(("bale_lost", {"bale": bale.id, "job_id": bale.job_id, "why": "landed on land"}))
            elif new == "floating":
                self.events.append(("bale_splash", {"bale": bale.id, "job_id": bale.job_id, "x": bale.x, "y": bale.y}))
            elif new == "sunk":
                self.events.append(("bale_lost", {"bale": bale.id, "job_id": bale.job_id, "why": "sank"}))
        floating = [b for b in self.bales if b.state == "floating"]
        for boat in list(self.boats):
            if boat.kind == "gofast":
                self._gofast(boat, dt, floating)
            else:
                self._cutter(boat, dt, floating, law_goals or [])
        self.bales = [b for b in self.bales if b.state in ("falling", "floating") or b.t_state < 5]

    def _gofast(self, b: Boat, dt: float, floating: list[Bale]) -> None:
        if b.state in ("seized", "delivered"):
            return
        mine = [bl for bl in floating if bl.job_id == b.job_id]
        # a cutter close by? run for it
        threat = min((c for c in self.boats if c.kind == "cutter" and c.state != "standby"),
                     key=lambda c: math.hypot(c.x - b.x, c.y - b.y), default=None)
        if threat and math.hypot(threat.x - b.x, threat.y - b.y) < 2500 and b.state not in ("fleeing",):
            b.state = "fleeing"
            self.events.append(("boat_fleeing", {"boat": b.id}))
        if b.state == "fleeing":
            b.steer(dt, self.world, self.cove)
            if threat is None or math.hypot(threat.x - b.x, threat.y - b.y) > 5000:
                b.state = "collecting" if mine else "running"
            if math.hypot(self.cove[0] - b.x, self.cove[1] - b.y) < 80:
                self._deliver(b)
            return
        if b.state == "to_rendezvous":
            if b.steer(dt, self.world, b.goal, 1.0) < 150:
                b.state = "waiting"
        elif b.state == "waiting":
            b.wait_t += dt
            b.steer(dt, self.world, b.goal, 0.0)
            if mine:
                b.state = "collecting"
            elif b.wait_t > 900:
                b.state = "running"
        if b.state == "collecting":
            if not mine:
                b.state = "running" if b.cargo else "waiting"
                return
            tgt = min(mine, key=lambda bl: math.hypot(bl.x - b.x, bl.y - b.y))
            d = b.steer(dt, self.world, (tgt.x, tgt.y), 0.6)
            if d < PICKUP_RADIUS_M:
                b.work_t += dt
                if b.work_t >= PICKUP_TIME_S:
                    b.work_t = 0.0
                    tgt.state = "collected"
                    b.cargo.append(tgt.id)
                    self.events.append(("bale_collected", {"boat": b.id, "job_id": b.job_id, "bale": tgt.id}))
        elif b.state == "running":
            if b.steer(dt, self.world, self.cove) < 80:
                self._deliver(b)

    def _deliver(self, b: Boat) -> None:
        b.state = "delivered"
        self.events.append(("bales_delivered", {"boat": b.id, "job_id": b.job_id, "count": len(b.cargo)}))

    def _cutter(self, c: Boat, dt: float, floating: list[Bale], law_goals: list[tuple[float, float]]) -> None:
        if c.state == "standby":
            if law_goals:
                c.goal, c.state = law_goals[-1], "patrol"
            else:
                return
        # surface radar: nearest runner boat still at sea
        runners = [b for b in self.boats if b.kind == "gofast" and b.state not in ("seized", "delivered")]
        seen = [b for b in runners if math.hypot(b.x - c.x, b.y - c.y) < SURFACE_RADAR_M]
        if seen:
            tgt = min(seen, key=lambda b: math.hypot(b.x - c.x, b.y - c.y))
            if c.target_id != tgt.id:
                c.target_id = tgt.id
                self.events.append(("cutter_contact", {"cutter": c.id, "boat": tgt.id, "x": tgt.x, "y": tgt.y}))
            d = c.steer(dt, self.world, (tgt.x + tgt.vx * 20, tgt.y + tgt.vy * 20))
            if d < SEIZE_RADIUS_M:
                tgt.seize_meter += dt
                if tgt.seize_meter >= SEIZE_TIME_S:
                    tgt.state = "seized"
                    self.events.append(("boat_seized", {"boat": tgt.id, "job_id": tgt.job_id, "count": len(tgt.cargo),
                                                        "cutter": c.id}))
            else:
                tgt.seize_meter = max(0.0, tgt.seize_meter - dt)
            return
        c.target_id = None
        near = [bl for bl in floating if math.hypot(bl.x - c.x, bl.y - c.y) < SURFACE_RADAR_M * 0.6]
        if near:
            bl = min(near, key=lambda bl: math.hypot(bl.x - c.x, bl.y - c.y))
            if c.steer(dt, self.world, (bl.x, bl.y), 0.7) < 60:
                c.work_t += dt
                if c.work_t > 3.0:
                    c.work_t = 0.0
                    bl.state = "seized"
                    self.events.append(("bale_seized", {"cutter": c.id, "job_id": bl.job_id, "bale": bl.id}))
            return
        if c.goal:
            if c.steer(dt, self.world, c.goal, 0.8) < 200:
                c.goal = None
        elif c.state == "return" or not law_goals:
            if c.steer(dt, self.world, c.home, 0.5) < 100:
                c.state = "standby"
        else:
            c.goal = law_goals[-1]
