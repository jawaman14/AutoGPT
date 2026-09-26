"""Radio: police dispatch, runner calls, scanners and direction finding.

- Police traffic is plain voice unless the task force pays for encryption.
  A runner scanner hears plain traffic verbatim (unit, base, heading),
  and hears static when it's encrypted.
- Every runner transmission (calling the boat) can be heard by DF stations.
  One bearing gives a line, two give a fix with a few hundred metres of error.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

DF_RANGE_M = 30_000.0
DF_SIGMA_DEG = 2.5


@dataclass
class RadioMsg:
    t: float
    channel: str  # police | runner
    sender: str
    text: str
    x: float | None = None
    y: float | None = None
    encrypted: bool = False


@dataclass
class Bearing:
    station: str
    x: float
    y: float
    deg: float


@dataclass
class DFResult:
    bearings: list[Bearing]
    fix: tuple[float, float] | None


def intersect(b1: Bearing, b2: Bearing) -> tuple[float, float] | None:
    d1 = (math.sin(math.radians(b1.deg)), math.cos(math.radians(b1.deg)))
    d2 = (math.sin(math.radians(b2.deg)), math.cos(math.radians(b2.deg)))
    det = d1[0] * -d2[1] - d1[1] * -d2[0]
    if abs(det) < 0.08:  # nearly parallel: useless fix
        return None
    rx, ry = b2.x - b1.x, b2.y - b1.y
    t1 = (rx * -d2[1] - ry * -d2[0]) / det
    t2 = (d1[0] * ry - d1[1] * rx) / det
    if t1 < 0 or t2 < 0:
        return None
    return b1.x + d1[0] * t1, b1.y + d1[1] * t1


@dataclass
class RadioNet:
    rng: random.Random = field(default_factory=random.Random)
    encrypted: bool = False
    log: list[RadioMsg] = field(default_factory=list)
    df_stations: list[tuple[str, float, float]] = field(default_factory=list)
    df_enabled: bool = False

    def transmit(self, t: float, channel: str, sender: str, text: str, pos=None) -> RadioMsg:
        msg = RadioMsg(t, channel, sender, text, *(pos or (None, None)),
                       encrypted=self.encrypted and channel == "police")
        self.log.append(msg)
        del self.log[:-300]
        return msg

    def scanner(self, since: float) -> list[tuple[float, str]]:
        """What a runner scanner hears on the police channel."""
        out = []
        for m in self.log:
            if m.t <= since or m.channel != "police":
                continue
            out.append((m.t, "[scrambled: encrypted traffic]" if m.encrypted else f"{m.sender}: {m.text}"))
        return out

    def channel(self, name: str, since: float = -1.0) -> list[RadioMsg]:
        return [m for m in self.log if m.channel == name and m.t > since]

    def direction_find(self, msg: RadioMsg) -> DFResult:
        if not self.df_enabled or msg.x is None:
            return DFResult([], None)
        bearings = []
        for code, sx, sy in self.df_stations:
            d = math.hypot(msg.x - sx, msg.y - sy)
            if d > DF_RANGE_M or d < 1:
                continue
            true = math.degrees(math.atan2(msg.x - sx, msg.y - sy))
            bearings.append(Bearing(code, sx, sy, (true + self.rng.gauss(0, DF_SIGMA_DEG)) % 360))
        fix = None
        for i in range(len(bearings)):
            for j in range(i + 1, len(bearings)):
                fix = fix or intersect(bearings[i], bearings[j])
        return DFResult(bearings, fix)
