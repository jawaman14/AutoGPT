"""Thin game-facing wrapper around a JSBSim FGFDMExec instance.

World frame used by the rest of the game: x = east (m), y = north (m),
z = up (m, above sea level). JSBSim works in geodetic lat/lon on WGS84; we map
the play area onto a small patch around (LAT0, LON0) where a local tangent
plane is accurate to well under a metre.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Callable

import jsbsim

from .aircraft import AircraftSpec
from .jsbsim_patch import MassData
from .loadout import Loadout

FT = 0.3048
KT = 0.514444
LAT0, LON0 = 0.0, 0.0

# WGS84 metres per degree at LAT0
_phi = math.radians(LAT0)
M_PER_DEG_LAT = 111132.92 - 559.82 * math.cos(2 * _phi) + 1.175 * math.cos(4 * _phi)
M_PER_DEG_LON = 111412.84 * math.cos(_phi) - 93.5 * math.cos(3 * _phi)


def xy_to_latlon(x: float, y: float) -> tuple[float, float]:
    return LAT0 + y / M_PER_DEG_LAT, LON0 + x / M_PER_DEG_LON


def latlon_to_xy(lat: float, lon: float) -> tuple[float, float]:
    return (lon - LON0) * M_PER_DEG_LON, (lat - LAT0) * M_PER_DEG_LAT


@dataclass
class Controls:
    aileron: float = 0.0  # -1 left .. +1 right
    elevator: float = 0.0  # -1 nose up .. +1 nose down (JSBSim convention)
    rudder: float = 0.0
    throttle: float = 0.0
    flaps: float = 0.0  # 0..1
    brake: float = 0.0
    pitch_trim: float = 0.0


@dataclass
class FlightState:
    x: float
    y: float
    alt: float  # CG altitude ASL, m
    agl: float  # CG height above the terrain JSBSim sees, m
    heading: float  # deg true, 0 = north, clockwise
    pitch: float  # deg
    roll: float  # deg, right wing down positive
    ias_kts: float
    gs_kts: float
    vs_fpm: float
    alpha_deg: float
    on_ground: bool
    wow_count: int
    fuel_lb: float
    weight_lb: float
    cg_in: float
    rpm: float
    engine_running: bool
    stall_warning: bool
    valid: bool
    vx: float = 0.0  # world velocity m/s
    vy: float = 0.0
    p_dps: float = 0.0  # roll rate
    q_dps: float = 0.0  # pitch rate
    fuel_flow_pph: float = 0.0


class FlightModel:
    def __init__(self, spec: AircraftSpec, root: str, mass: MassData):
        self.spec = spec
        self.mass = mass
        self.fdm = jsbsim.FGFDMExec(root)
        self.fdm.set_debug_level(0)
        if not self.fdm.load_model(spec.jsbsim_model):
            raise RuntimeError(f"JSBSim failed to load {spec.jsbsim_model}")
        self.dt = self.fdm.get_delta_t()
        self._pm = self.fdm.get_property_manager()
        self.n_engines = self._count_engines()
        self.n_gear = self._count("gear/unit[{}]/WOW")
        self.controls = Controls()
        self._accum = 0.0
        self.sim_time = 0.0
        self.last_touchdown_fpm = 0.0
        self.touchdowns = 0
        self.crash_reason: str | None = None
        self._prev_ground = True

    # ------------------------------------------------------------------ setup
    def _count(self, pattern: str) -> int:
        n = 0
        while self._pm.hasNode(pattern.format(n)):
            n += 1
        return n

    def _count_engines(self) -> int:
        return max(1, self._count("propulsion/engine[{}]/set-running"))

    def has(self, prop: str) -> bool:
        return self._pm.hasNode(prop)

    def apply_loadout(self, lo: Loadout) -> None:
        for i, w in enumerate(lo.station_weights()):
            self.fdm[f"inertia/pointmass-weight-lbs[{i}]"] = w
        for i, f in enumerate(lo.tank_fuel()):
            self.fdm[f"propulsion/tank[{i}]/contents-lbs"] = f

    def spawn(
        self,
        x: float,
        y: float,
        heading_deg: float,
        terrain_m: float,
        loadout: Loadout,
        airborne_alt_m: float | None = None,
        speed_kts: float = 0.0,
    ) -> None:
        f = self.fdm
        lat, lon = xy_to_latlon(x, y)
        f["ic/lat-geod-deg"] = lat
        f["ic/long-gc-deg"] = lon
        f["ic/terrain-elevation-ft"] = terrain_m / FT
        if airborne_alt_m is None:
            f["ic/h-agl-ft"] = self.mass.gear_height_ft + 0.2
        else:
            f["ic/h-sl-ft"] = airborne_alt_m / FT
        f["ic/psi-true-deg"] = heading_deg
        f["ic/theta-deg"] = 0.0
        f["ic/phi-deg"] = 0.0
        f["ic/u-fps"] = speed_kts * KT / FT
        f["ic/v-fps"] = 0.0
        f["ic/w-fps"] = 0.0
        f["ic/p-rad_sec"] = 0.0
        f["ic/q-rad_sec"] = 0.0
        f["ic/r-rad_sec"] = 0.0
        self.apply_loadout(loadout)
        f.run_ic()
        self.apply_loadout(loadout)  # run_ic may reset tank contents from the XML
        self.start_engines()
        self._prev_ground = airborne_alt_m is None
        self.last_touchdown_fpm = 0.0
        self.crash_reason = None
        self._accum = 0.0

    def start_engines(self) -> None:
        f = self.fdm
        f["propulsion/magneto_cmd"] = 3
        f["propulsion/starter_cmd"] = 1
        for i in range(self.n_engines):
            f[f"fcs/mixture-cmd-norm[{i}]"] = 1.0
            f[f"fcs/advance-cmd-norm[{i}]"] = 1.0
        f["propulsion/set-running"] = -1

    # ------------------------------------------------------------------ loop
    def _push_controls(self) -> None:
        f, c = self.fdm, self.controls
        f["fcs/aileron-cmd-norm"] = c.aileron
        f["fcs/elevator-cmd-norm"] = c.elevator
        # JSBSim: +rudder-cmd yaws nose left (FlightGear negates it too),
        # +steer-cmd turns the nosewheel right.
        f["fcs/rudder-cmd-norm"] = -c.rudder
        f["fcs/flap-cmd-norm"] = c.flaps
        f["fcs/pitch-trim-cmd-norm"] = c.pitch_trim
        for i in range(self.n_engines):
            f[f"fcs/throttle-cmd-norm[{i}]"] = c.throttle
        left = right = c.brake
        if self.spec.toe_brake_steering and self._prev_ground:
            # no steerable nosewheel in the model: pedals feed differential braking
            left = max(left, -c.rudder * 0.35)
            right = max(right, c.rudder * 0.35)
        f["fcs/left-brake-cmd-norm"] = left
        f["fcs/right-brake-cmd-norm"] = right
        f["fcs/center-brake-cmd-norm"] = c.brake
        if self.has("fcs/steer-cmd-norm"):
            f["fcs/steer-cmd-norm"] = c.rudder

    def step(self, frame_dt: float, terrain_at: Callable[[float, float], float]) -> FlightState:
        """Advance the FDM by frame_dt seconds of real time using fixed JSBSim sub-steps."""
        self._push_controls()
        self._accum += min(frame_dt, 0.1)
        while self._accum >= self.dt and self.crash_reason is None:
            x, y = self.position_xy()
            ground_ft = terrain_at(x, y) / FT
            # Rising terrain arrives as a step in JSBSim's flat-earth ground
            # plane; if it would bury the gear, that is a controlled flight
            # into terrain, not something the gear springs should resolve.
            if self.fdm["position/h-sl-ft"] - ground_ft < self.mass.gear_height_ft * 0.5:
                self.crash_reason = "Flew into terrain"
                break
            self.fdm["position/terrain-elevation-asl-ft"] = ground_ft
            vs = -self.fdm["velocities/v-down-fps"] * 60.0
            self.fdm.run()
            self.sim_time += self.dt
            self._accum -= self.dt
            ground = self.wow_count() > 0
            if ground and not self._prev_ground:
                self.last_touchdown_fpm = vs
                self.touchdowns += 1
            self._prev_ground = ground
        return self.state()

    # ------------------------------------------------------------------ read
    def position_xy(self) -> tuple[float, float]:
        return latlon_to_xy(self.fdm["position/lat-geod-deg"], self.fdm["position/long-gc-deg"])

    def wow_count(self) -> int:
        return sum(1 for i in range(self.n_gear) if self.fdm[f"gear/unit[{i}]/WOW"] > 0.5)

    def fuel_lb(self) -> float:
        return self.fdm["propulsion/total-fuel-lbs"]

    def fuel_flow_pph(self) -> float:
        total = 0.0
        for i in range(self.n_engines):
            prop = f"propulsion/engine[{i}]/fuel-flow-rate-pps"
            if self.has(prop):
                v = self.fdm[prop]
                total += v if math.isfinite(v) else 0.0
        return total * 3600.0

    def add_fuel(self, lb: float) -> float:
        """Pour fuel into the wing tanks (ferry transfer). Returns what fit."""
        added = 0.0
        caps = self.mass.tanks
        for i, (_, cap) in enumerate(caps):
            if lb - added <= 0:
                break
            prop = f"propulsion/tank[{i}]/contents-lbs"
            cur = self.fdm[prop]
            room = max(0.0, cap - cur)
            share = min(room, (lb - added) if i == len(caps) - 1 else lb / len(caps))
            self.fdm[prop] = cur + share
            added += share
        return added

    def wing_fuel_room(self) -> float:
        return sum(max(0.0, cap - self.fdm[f"propulsion/tank[{i}]/contents-lbs"]) for i, (_, cap) in enumerate(self.mass.tanks))

    def state(self) -> FlightState:
        f = self.fdm
        x, y = self.position_xy()
        alt = f["position/h-sl-ft"] * FT
        vals = (alt, f["attitude/theta-deg"], f["velocities/vc-kts"])
        valid = all(math.isfinite(v) for v in vals)
        rpm = f["propulsion/engine/engine-rpm"] if self.has("propulsion/engine/engine-rpm") else 0.0
        stall = (
            f["aero/alpha-deg"] > 15.0
            and self.wow_count() == 0
        )
        return FlightState(
            x=x,
            y=y,
            alt=alt,
            agl=f["position/h-agl-ft"] * FT,
            heading=f["attitude/psi-deg"],
            pitch=f["attitude/theta-deg"],
            roll=f["attitude/phi-deg"],
            ias_kts=f["velocities/vc-kts"],
            gs_kts=f["velocities/vg-fps"] * FT / KT,
            vs_fpm=-f["velocities/v-down-fps"] * 60.0,
            alpha_deg=f["aero/alpha-deg"],
            on_ground=self.wow_count() > 0,
            wow_count=self.wow_count(),
            fuel_lb=self.fuel_lb(),
            weight_lb=f["inertia/weight-lbs"],
            cg_in=f["inertia/cg-x-in"],
            rpm=rpm if math.isfinite(rpm) else 0.0,
            engine_running=bool(f["propulsion/engine/set-running"]),
            stall_warning=stall,
            valid=valid,
            vx=f["velocities/v-east-fps"] * FT,
            vy=f["velocities/v-north-fps"] * FT,
            p_dps=math.degrees(f["velocities/p-rad_sec"]),
            q_dps=math.degrees(f["velocities/q-rad_sec"]),
            fuel_flow_pph=self.fuel_flow_pph(),
        )
