"""Simple two-axis autopilot: heading hold (through bank) and altitude hold.

Cascade: altitude error -> target vertical speed -> target flight-path angle
-> target pitch (with an integrator that learns the trim pitch) -> elevator
(PD on pitch + integrator). Heading error -> target bank -> aileron (PD).
It exists so a solo pilot can leave the controls and go aft to kick bales.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

from .fdm import Controls, FlightState


def _clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def _wrap180(a: float) -> float:
    return (a + 180.0) % 360.0 - 180.0


@dataclass
class Autopilot:
    engaged: bool = False
    alt_target: float = 0.0  # m MSL
    hdg_target: float = 0.0
    pitch_base: float = 2.0  # learned trim pitch, deg
    elev_i: float = 0.0
    min_ias_kts: float = 0.0  # below this, give up altitude to keep flying speed

    def engage(self, s: FlightState, elevator_now: float = 0.0) -> None:
        self.engaged = True
        self.alt_target = s.alt
        self.hdg_target = s.heading
        self.pitch_base = s.pitch
        self.elev_i = elevator_now

    def disengage(self) -> None:
        self.engaged = False

    def update(self, dt: float, s: FlightState, c: Controls) -> Controls:
        if not self.engaged or s.on_ground:
            return c
        # lateral
        bank_t = _clamp(_wrap180(self.hdg_target - s.heading) * 1.2, -18.0, 18.0)
        c.aileron = _clamp(0.04 * (bank_t - s.roll) - 0.012 * s.p_dps, -0.6, 0.6)
        c.rudder = 0.0
        # vertical
        vs_t = _clamp((self.alt_target - s.alt) * 18.0, -600.0, 600.0)  # fpm
        tas = max(20.0, s.ias_kts * 0.514444)
        gamma_t = math.degrees(math.atan2(vs_t * 0.00508, tas))
        self.pitch_base = _clamp(self.pitch_base + (vs_t - s.vs_fpm) * 0.0006 * dt, -6.0, 12.0)
        pitch_t = _clamp(self.pitch_base + gamma_t, -8.0, 14.0)
        if s.ias_kts < self.min_ias_kts:
            pitch_t = min(pitch_t, s.pitch - (self.min_ias_kts - s.ias_kts) * 0.6)
            self.pitch_base = min(self.pitch_base, pitch_t)
        err = pitch_t - s.pitch
        self.elev_i = _clamp(self.elev_i - err * 0.02 * dt, -0.6, 0.6)
        c.elevator = _clamp(-0.07 * err + 0.03 * s.q_dps + self.elev_i, -0.8, 0.8)
        return c
