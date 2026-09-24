"""Detection: signatures in, noisy tracks out.

Nobody on the law side sees the truth. Radars turn target signatures into
tracks with position noise and an age; units that lose the track fly to the
last known position. The same geometry drives the runner's radar detector
("painted" = a radar has line of sight to you, "locked" = it can actually
see you above its clutter floor or through your transponder).
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from .world import World


@dataclass
class Signature:
    id: str
    x: float
    y: float
    z: float  # altitude MSL, m
    agl: float
    vx: float = 0.0
    vy: float = 0.0
    kind: str = "air"  # air | surface
    transponder: bool = False
    squawk: str = ""

    @property
    def speed_kts(self) -> float:
        return math.hypot(self.vx, self.vy) / 0.514444


@dataclass
class RadarSite:
    code: str
    name: str
    x: float
    y: float
    mast_z: float  # absolute height of the antenna, m MSL
    range_m: float
    floor_base: float = 45.0  # m AGL below which primary returns are lost in clutter
    floor_per_m: float = 0.009
    kind: str = "ground"  # ground | aerostat
    active: bool = True

    def floor(self, dist_m: float) -> float:
        return self.floor_base + dist_m * self.floor_per_m

    def check(self, world: World, sig: Signature) -> tuple[bool, bool]:
        """(painted, detected)"""
        if not self.active or sig.kind != "air":
            return False, False
        d = math.hypot(sig.x - self.x, sig.y - self.y)
        if d > self.range_m:
            return False, False
        if not world.line_of_sight((self.x, self.y, self.mast_z), (sig.x, sig.y, sig.z), step=250.0):
            return False, False
        if sig.transponder:
            return True, True  # secondary radar: the transponder answers regardless of clutter
        return True, sig.agl >= self.floor(d)


@dataclass
class Track:
    target_id: str
    x: float
    y: float
    z: float
    vx: float
    vy: float
    t: float  # time of last update
    source: str
    squawk: str | None = None  # identity, only with transponder on
    first_t: float = 0.0

    def age(self, now: float) -> float:
        return now - self.t

    def predicted(self, now: float, max_s: float = 20.0) -> tuple[float, float]:
        dt = min(max_s, self.age(now))
        return self.x + self.vx * dt, self.y + self.vy * dt


@dataclass
class Detection:
    painted_by: list[str] = field(default_factory=list)
    detected_by: list[str] = field(default_factory=list)

    @property
    def detector_level(self) -> str:
        """What the runner's radar detector shows."""
        if self.detected_by:
            return "LOCK"
        if self.painted_by:
            return "PAINT"
        return ""


AEROSTAT_POS = (1500.0, -14800.0)


def default_sites(world: World) -> list[RadarSite]:
    sites = [
        RadarSite(a.code, f"{a.name} radar", a.x, a.y, world.airfield_elev(a) + 30, a.radar_km * 1000)
        for a in world.airfields
        if a.radar_km > 0
    ]
    # The tethered balloon ("Fat Albert" in the real Keys). Off until the task force raises it.
    sites.append(RadarSite("AER", "Aerostat radar", *AEROSTAT_POS, mast_z=2500.0, range_m=40_000,
                           floor_base=20.0, floor_per_m=0.003, kind="aerostat", active=False))
    return sites


class SensorNet:
    TRACK_TIMEOUT = 45.0

    def __init__(self, world: World, rng: random.Random | None = None):
        self.world = world
        self.rng = rng or random.Random(0)
        self.sites = default_sites(world)
        self.tracks: dict[str, Track] = {}

    def site(self, code: str) -> RadarSite | None:
        return next((s for s in self.sites if s.code == code), None)

    def sweep(self, sigs: list[Signature], now: float) -> dict[str, Detection]:
        out: dict[str, Detection] = {}
        for sig in sigs:
            det = Detection()
            for site in self.sites:
                painted, detected = site.check(self.world, sig)
                if painted:
                    det.painted_by.append(site.code)
                if detected:
                    det.detected_by.append(site.code)
            if det.detected_by:
                src = det.detected_by[0]
                site = self.site(src)
                d = math.hypot(sig.x - site.x, sig.y - site.y)
                sigma = 40 + 0.004 * d
                self.report(sig, now, src, sigma)
            out[sig.id] = det
        self.expire(now)
        return out

    def report(self, sig: Signature, now: float, source: str, sigma: float = 0.0) -> Track:
        nx = self.rng.gauss(0, sigma) if sigma else 0.0
        ny = self.rng.gauss(0, sigma) if sigma else 0.0
        prev = self.tracks.get(sig.id)
        tr = Track(sig.id, sig.x + nx, sig.y + ny, sig.z, sig.vx, sig.vy, now, source,
                   sig.squawk if sig.transponder else None, first_t=prev.first_t if prev else now)
        self.tracks[sig.id] = tr
        return tr

    def add_fix(self, target_id: str, x: float, y: float, now: float, source: str) -> Track:
        """A position with no velocity (DF fix, tip, spotter report)."""
        prev = self.tracks.get(target_id)
        tr = Track(target_id, x, y, prev.z if prev else 300.0, 0.0, 0.0, now, source,
                   first_t=prev.first_t if prev else now)
        self.tracks[target_id] = tr
        return tr

    def expire(self, now: float) -> None:
        for tid in [k for k, t in self.tracks.items() if t.age(now) > self.TRACK_TIMEOUT]:
            del self.tracks[tid]
