"""AI runner flights for the task-force side to hunt.

A kinematic aircraft that comes in from the edge of the map at low level,
flies to a drop point at sea, circles while kicking bales to a waiting boat,
and runs for the map edge. It dives and turns away when it sees a police unit.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from .fdm import KT
from .sensors import Signature
from .world import HALF, World


def _wrap180(a: float) -> float:
    return (a + 180.0) % 360.0 - 180.0


@dataclass
class AISmuggler:
    id: str
    x: float
    y: float
    z: float
    heading: float
    drop_point: tuple[float, float]
    exit_point: tuple[float, float]
    job_id: int
    bales_left: int = 6
    speed: float = 140 * KT
    state: str = "inbound"  # inbound | dropping | outbound | escaped | busted | crashed
    agl_target: float = 70.0
    evade_t: float = 0.0
    kick_t: float = 0.0
    orbit_t: float = 0.0
    vx: float = 0.0
    vy: float = 0.0
    squawk: str = ""
    hot: bool = True  # False: a decoy flying the same profile with nothing aboard
    kind: str = "ai"  # ai (police-mode traffic) | crew (organisation contract run) | decoy

    @property
    def active(self) -> bool:
        return self.state in ("inbound", "dropping", "outbound")

    def signature(self, world: World) -> Signature:
        return Signature(self.id, self.x, self.y, self.z, self.z - world.ground(self.x, self.y),
                         self.vx, self.vy, "air", transponder=False)

    def update(self, dt: float, world: World, threats: list[tuple[float, float, float]], drop_fn) -> str | None:
        """drop_fn(job_id, x, y, z, vx, vy) spawns a bale. Returns a state transition name."""
        if not self.active:
            return None
        turn = 9.0
        if self.state == "inbound":
            goal = self.drop_point
        elif self.state == "dropping":
            goal = None
        else:
            goal = self.exit_point
        # evasion: nearest threat within 4 km -> dive and break away
        near = min(threats, key=lambda t: math.hypot(t[0] - self.x, t[1] - self.y), default=None)
        if near and math.hypot(near[0] - self.x, near[1] - self.y) < 4000:
            self.evade_t = 20.0
        if self.evade_t > 0:
            self.evade_t -= dt
            self.agl_target = 35.0
            if near:
                away = math.degrees(math.atan2(self.x - near[0], self.y - near[1]))
                if goal:
                    to_goal = math.degrees(math.atan2(goal[0] - self.x, goal[1] - self.y))
                    desired = to_goal + _wrap180(away - to_goal) * 0.6
                else:
                    desired = away
            else:
                desired = self.heading
            speed = 165 * KT
        elif self.state == "dropping":
            self.agl_target = 120.0
            desired = self.heading + 12.0  # standard-rate-ish orbit
            speed = 100 * KT
        else:
            self.agl_target = 70.0
            desired = math.degrees(math.atan2(goal[0] - self.x, goal[1] - self.y))
            speed = 140 * KT
        err = _wrap180(desired - self.heading)
        self.heading = (self.heading + max(-turn * dt, min(turn * dt, err))) % 360
        self.speed += max(-5 * dt, min(5 * dt, speed - self.speed))
        h = math.radians(self.heading)
        self.vx, self.vy = math.sin(h) * self.speed, math.cos(h) * self.speed
        # terrain following with a 600 m look-ahead
        ahead = max(world.ground(self.x + self.vx * t, self.y + self.vy * t) for t in (0.0, 3.0, 6.0, 10.0))
        tz = ahead + self.agl_target
        self.z += max(-8 * dt, min(10 * dt, tz - self.z))
        self.x += self.vx * dt
        self.y += self.vy * dt
        if self.z < world.ground(self.x, self.y) + 2:
            self.state = "crashed"
            return "crashed"

        if self.state == "inbound" and math.hypot(self.drop_point[0] - self.x, self.drop_point[1] - self.y) < 500:
            self.state = "dropping"
            return "dropping"
        if self.state == "dropping":
            self.orbit_t += dt
            self.kick_t += dt
            if self.kick_t > 4.0 and self.bales_left > 0 and world.is_water(self.x, self.y):
                self.kick_t = 0.0
                self.bales_left -= 1
                drop_fn(self.job_id, self.x, self.y, self.z, self.vx, self.vy)
            if self.bales_left == 0 or self.orbit_t > 150:
                self.state = "outbound"
                return "outbound"
        if self.state == "outbound" and (abs(self.x) > HALF + 500 or abs(self.y) > HALF + 500):
            self.state = "escaped"
            return "escaped"
        return None


def entry_and_exit(rng: random.Random) -> tuple[tuple[float, float], tuple[float, float], float]:
    """A point just outside the map on the south/east (where the flights came from) and an exit."""
    side = rng.choice(("south", "east", "southeast"))
    if side == "south":
        entry = (rng.uniform(-HALF * 0.6, HALF * 0.6), -HALF - 400)
    elif side == "east":
        entry = (HALF + 400, rng.uniform(-HALF * 0.6, HALF * 0.3))
    else:
        entry = (HALF + 200, -HALF - 200)
    exit_ = rng.choice(((rng.uniform(-HALF, HALF), -HALF - 800), (HALF + 800, rng.uniform(-HALF, 0))))
    heading = math.degrees(math.atan2(-entry[0], -entry[1])) % 360
    return entry, exit_, heading


@dataclass
class SmugglerDirector:
    """Spawns AI runs for the police-vs-AI mode."""
    rng: random.Random = field(default_factory=random.Random)
    first_at: float = 20.0
    interval: float = 150.0
    max_active: int = 2
    next_t: float = 20.0
    serial: int = 0

    def due(self, now: float, active: int) -> bool:
        return now >= self.next_t and active < self.max_active

    def schedule_next(self, now: float) -> None:
        self.next_t = now + self.interval * self.rng.uniform(0.7, 1.3)
