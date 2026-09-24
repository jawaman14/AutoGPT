"""Police radar, wanted level, and pursuit AI (police + rival smugglers).

Pursuers are kinematic point-masses with turn/climb/speed limits and a short
terrain look-ahead. They are *not* JSBSim aircraft: that keeps them cheap, and
the imperfect terrain avoidance is deliberate - drag them through a canyon and
they can fly into the wall.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from .fdm import KT, FlightState
from .world import World, Airfield

UNIT_TYPES = {
    #            max kts, turn deg/s, climb m/s, look-ahead m, faction
    "heli":        (120, 14.0, 7.0, 500.0, "police"),
    "interceptor": (230, 9.0, 15.0, 900.0, "police"),
    "rival":       (170, 11.0, 9.0, 700.0, "rival"),
}

BUST_RANGE_M = 350.0
RIVAL_RANGE_M = 250.0
SIGHT_RANGE_M = 4500.0
LANDING_BUST_RANGE_M = 2500.0


def _wrap180(a: float) -> float:
    return (a + 180.0) % 360.0 - 180.0


@dataclass
class Pursuer:
    kind: str
    x: float
    y: float
    z: float
    heading: float
    home: tuple[float, float]
    speed: float = 0.0  # m/s
    state: str = "pursuit"  # pursuit | return | crashed
    sees_player: bool = False
    crashed_timer: float = 0.0
    just_crashed: bool = False

    @property
    def spec(self):
        return UNIT_TYPES[self.kind]

    @property
    def faction(self) -> str:
        return self.spec[4]

    def dist_to(self, s: FlightState) -> float:
        return math.dist((self.x, self.y, self.z), (s.x, s.y, s.alt))

    def update(self, dt: float, target: FlightState | None, world: World) -> None:
        if self.state == "crashed":
            self.crashed_timer += dt
            return
        vmax_kts, turn, climb, look, _ = self.spec
        vmax = vmax_kts * KT
        if self.state == "pursuit" and target is not None:
            d = math.hypot(target.x - self.x, target.y - self.y)
            lead = min(8.0, d / max(vmax, 1.0))
            tx, ty = target.x + target.vx * lead, target.y + target.vy * lead
            tz = target.alt
            want_speed = vmax if d > 600 else max(35.0, math.hypot(target.vx, target.vy) * 1.05)
        else:
            tx, ty = self.home
            tz = world.ground(tx, ty) + 300
            want_speed = vmax * 0.7
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
class HeatEvent:
    text: str


@dataclass
class PoliceSystem:
    world: World
    rng: random.Random = field(default_factory=random.Random)
    suspicion: float = 0.0  # 0..100
    wanted: int = 0  # 0..3
    bust_meter: float = 0.0  # 0..100
    rival_meter: float = 0.0  # 0..100
    units: list[Pursuer] = field(default_factory=list)
    detected_by: str | None = None
    _seen_time: float = 0.0
    _unseen_time: float = 0.0
    _rival_spawned: bool = False
    _flight_time: float = 0.0
    events: list[str] = field(default_factory=list)

    def reset(self, keep_wanted: bool = False) -> None:
        self.suspicion = 0.0
        self.bust_meter = 0.0
        self.rival_meter = 0.0
        self.units.clear()
        self._seen_time = self._unseen_time = 0.0
        self._rival_spawned = False
        self._flight_time = 0.0
        if not keep_wanted:
            self.wanted = 0

    # ------------------------------------------------------------ radar
    def radar_sites(self) -> list[Airfield]:
        return [a for a in self.world.airfields if a.radar_km > 0]

    @staticmethod
    def radar_floor_agl(dist_m: float) -> float:
        """Below this height above ground the radar loses you in clutter."""
        return 45.0 + dist_m * 0.009  # ~135 m AGL at 10 km

    def radar_detects(self, s: FlightState) -> Airfield | None:
        for site in self.radar_sites():
            d = math.hypot(s.x - site.x, s.y - site.y)
            if d > site.radar_km * 1000:
                continue
            agl = s.alt - self.world.ground(s.x, s.y)
            if agl < self.radar_floor_agl(d):
                continue
            mast = (site.x, site.y, self.world.airfield_elev(site) + 30)
            if self.world.line_of_sight(mast, (s.x, s.y, s.alt)):
                return site
        return None

    # ------------------------------------------------------------ dispatch
    def _spawn(self, kind: str, near: tuple[float, float] | None = None) -> None:
        police_bases = [a for a in self.world.airfields if a.police]
        if kind == "rival" and near is not None:
            ang = self.rng.uniform(0, 2 * math.pi)
            x, y = near[0] + 5000 * math.cos(ang), near[1] + 5000 * math.sin(ang)
            home = (x, y)
        else:
            base = min(police_bases, key=lambda a: (a.x - near[0]) ** 2 + (a.y - near[1]) ** 2) if near else police_bases[0]
            x, y = base.x, base.y
            home = (x, y)
        z = self.world.ground(x, y) + 250
        self.units.append(Pursuer(kind, x, y, z, 0.0, home, speed=UNIT_TYPES[kind][0] * KT * 0.6))

    def _set_wanted(self, level: int, s: FlightState) -> None:
        level = max(0, min(3, level))
        if level > self.wanted:
            self.events.append(f"WANTED LEVEL {level}")
            active = [u for u in self.units if u.faction == "police" and u.state == "pursuit"]
            need = {1: ["heli"], 2: ["heli", "interceptor"], 3: ["heli", "interceptor", "interceptor"]}[level]
            have = [u.kind for u in active]
            for k in need:
                if k in have:
                    have.remove(k)
                else:
                    self._spawn(k, (s.x, s.y))
        elif level < self.wanted:
            self.events.append("Wanted level down" if level else "You lost them. Heat is off.")
            if level == 0:
                for u in self.units:
                    if u.faction == "police":
                        u.state = "return"
        self.wanted = level

    # ------------------------------------------------------------ tick
    def update(self, dt: float, s: FlightState, carrying_hot: bool, hot_value: int) -> str | None:
        """Returns "busted" or "hijacked" when the chase ends badly for the player."""
        self._flight_time += dt
        site = self.radar_detects(s) if (carrying_hot or self.wanted) else None
        self.detected_by = site.code if site else None
        if site and self.wanted == 0:
            d = math.hypot(s.x - site.x, s.y - site.y)
            self.suspicion += dt * (8 + 25 * (1 - d / (site.radar_km * 1000)))
            if self.suspicion >= 100:
                self.suspicion = 100
                self.events.append(f"{site.name} radar has you. Police dispatched!")
                self._set_wanted(1, s)
        elif self.wanted == 0:
            self.suspicion = max(0.0, self.suspicion - 5 * dt)

        # rivals: once per flight when carrying valuable contraband
        if carrying_hot and hot_value > 2000 and not self._rival_spawned and self._flight_time > 45:
            self._rival_spawned = True
            if self.rng.random() < 0.6:
                self._spawn("rival", (s.x, s.y))
                self.events.append("Rival smugglers inbound! Don't let them close in.")

        seen = False
        close_police = False
        close_rival = False
        for u in self.units:
            u.update(dt, s, self.world)
            if u.state == "crashed":
                if u.just_crashed:
                    u.just_crashed = False
                    self.events.append(f"The {u.faction} {u.kind} hit the terrain!")
                continue
            d = u.dist_to(s)
            u.sees_player = (
                u.state == "pursuit"
                and d < SIGHT_RANGE_M
                and self.world.line_of_sight((u.x, u.y, u.z), (s.x, s.y, s.alt), step=100)
            )
            if u.faction == "police" and u.sees_player:
                seen = True
                if d < BUST_RANGE_M:
                    close_police = True
            if u.faction == "rival" and u.sees_player and d < RIVAL_RANGE_M:
                close_rival = True
        self.units = [u for u in self.units if not (u.state == "crashed" and u.crashed_timer > 20)]
        self.units = [u for u in self.units if not (u.state == "return" and math.hypot(u.x - u.home[0], u.y - u.home[1]) < 300)]

        if self.wanted:
            if seen or site:
                self._seen_time += dt
                self._unseen_time = 0.0
                if self._seen_time > 60 and self.wanted < 3:
                    self._seen_time = 0.0
                    self._set_wanted(self.wanted + 1, s)
            else:
                self._unseen_time += dt
                if self._unseen_time > 15 + 12 * self.wanted:
                    self._unseen_time = 0.0
                    self._seen_time = 0.0
                    self._set_wanted(self.wanted - 1, s)
                    if self.wanted == 0:
                        self.suspicion = 0.0

        self.bust_meter = min(100.0, self.bust_meter + 22 * dt) if close_police else max(0.0, self.bust_meter - 12 * dt)
        self.rival_meter = min(100.0, self.rival_meter + 14 * dt) if close_rival else max(0.0, self.rival_meter - 10 * dt)
        if self.bust_meter >= 100:
            return "busted"
        if self.rival_meter >= 100:
            for u in self.units:
                if u.faction == "rival":
                    u.state = "return"
            self.rival_meter = 0.0
            return "hijacked"
        return None

    def landing_check(self, s: FlightState, field_: Airfield, carrying_hot: bool) -> bool:
        """Called once when the player comes to a stop. True -> busted."""
        for u in self.units:
            if u.faction == "police" and u.state == "pursuit" and u.dist_to(s) < LANDING_BUST_RANGE_M:
                return True
        if field_.police and self.wanted > 0:
            return True
        if field_.police and carrying_hot and self.rng.random() < 0.35:
            self.events.append("Customs inspection!")
            return True
        return False

    def nearest_threat(self, s: FlightState) -> tuple[Pursuer, float] | None:
        live = [u for u in self.units if u.state == "pursuit"]
        if not live:
            return None
        u = min(live, key=lambda u: u.dist_to(s))
        return u, u.dist_to(s)
