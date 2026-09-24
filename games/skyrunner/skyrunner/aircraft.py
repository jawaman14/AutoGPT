"""Aircraft roster.

Every flyable aircraft is a stock JSBSim model. The game adds what JSBSim does
not know about: load stations (seats / cargo bays) in JSBSim structural-frame
inches, a certified weight & CG envelope, price, and visual parameters for the
procedural 3D model.

Station and envelope numbers are loosely based on the real POH figures for each
type, adjusted to the datum and empty-weight values used by the JSBSim models
(the JSBSim files are not all built on the manufacturer's datum).
"""
from __future__ import annotations

from dataclasses import dataclass, field

LB_PER_KG = 2.20462


@dataclass(frozen=True)
class Station:
    name: str
    x_in: float
    y_in: float
    z_in: float
    max_lb: float
    kind: str  # "pilot" | "seat" | "cargo"

    def accepts(self, item_kind: str) -> bool:
        if self.kind == "pilot":
            return False
        if item_kind == "passenger":
            return self.kind == "seat"
        return True  # cargo can be strapped into seats too


@dataclass(frozen=True)
class Visual:
    wing: str  # "high" | "low"
    engines: int
    length_m: float
    span_m: float
    color: tuple[float, float, float]
    stripe: tuple[float, float, float]
    tricycle: bool = True


@dataclass(frozen=True)
class AircraftSpec:
    key: str
    jsbsim_model: str
    name: str
    price: int
    mtow_lb: float
    stations: tuple[Station, ...]
    # CG envelope polygon as (cg_in, weight_lb) points, counter-clockwise.
    envelope: tuple[tuple[float, float], ...]
    rotate_kts: float
    approach_kts: float
    max_flap_kts: float
    visual: Visual
    description: str = ""
    # landing ground roll at MTOW, sea level, flaps full (POH-ish), metres
    ground_roll_m: float = 180.0
    # touchdown sink rate (ft/min) beyond which the gear collapses
    gear_limit_fpm: float = 700.0
    toe_brake_steering: bool = False  # JSBSim model has no nosewheel steering
    extra_ic: dict = field(default_factory=dict)

    def est_landing_roll(self, weight_lb: float, elev_m: float) -> float:
        """Rough ground-roll estimate: scales ~W^2 (energy at a fixed CL) and with density altitude."""
        return self.ground_roll_m * (weight_lb / self.mtow_lb) ** 2 * (1 + 0.12 * elev_m / 1000)

    @property
    def pilot_station(self) -> int:
        return next(i for i, s in enumerate(self.stations) if s.kind == "pilot")


def _pairs(prefix: str, x: float, y: float, z: float, max_lb: float, kind: str):
    return (
        Station(f"{prefix} L", x, -y, z, max_lb, kind),
        Station(f"{prefix} R", x, y, z, max_lb, kind),
    )


C172P = AircraftSpec(
    key="c172p",
    jsbsim_model="c172p",
    name="Cessna 172P Skyhawk",
    price=0,
    mtow_lb=2400,
    stations=(
        Station("Pilot", 36, -14, 24, 250, "pilot"),
        Station("Co-pilot", 36, 14, 24, 250, "seat"),
        *_pairs("Rear", 70, 14, 24, 250, "seat"),
        Station("Baggage A", 95, 0, 24, 120, "cargo"),
        Station("Baggage B", 123, 0, 24, 50, "cargo"),
    ),
    envelope=((35.0, 1500), (47.3, 1500), (47.3, 2400), (39.5, 2400), (35.0, 1950)),
    rotate_kts=55,
    approach_kts=65,
    max_flap_kts=85,
    visual=Visual("high", 1, 8.3, 11.0, (0.93, 0.93, 0.95), (0.75, 0.1, 0.1)),
    description="The starter. Forgiving, slow, 4 seats, little payload with full tanks.",
    ground_roll_m=175,
)

C182 = AircraftSpec(
    key="c182",
    jsbsim_model="c182",
    name="Cessna 182 Skylane",
    price=85_000,
    mtow_lb=3100,
    stations=(
        Station("Pilot", 36, -14, 24, 250, "pilot"),
        Station("Co-pilot", 36, 14, 24, 250, "seat"),
        *_pairs("Rear", 72, 14, 24, 250, "seat"),
        Station("Baggage A", 97, 0, 24, 120, "cargo"),
        Station("Baggage B", 116, 0, 24, 80, "cargo"),
    ),
    envelope=((33.0, 1700), (46.5, 1700), (46.5, 3100), (40.9, 3100), (33.0, 2250)),
    rotate_kts=55,
    approach_kts=70,
    max_flap_kts=95,
    visual=Visual("high", 1, 8.8, 11.0, (0.95, 0.95, 0.9), (0.1, 0.25, 0.7)),
    description="More power and payload than the 172. Constant-speed prop.",
    ground_roll_m=180,
)

PA28 = AircraftSpec(
    key="pa28",
    jsbsim_model="pa28",
    name="Piper PA-28 Warrior",
    price=60_000,
    mtow_lb=2440,
    stations=(
        Station("Pilot", 80.5, -9.6, 0, 250, "pilot"),
        Station("Co-pilot", 80.5, 9.6, 0, 250, "seat"),
        *_pairs("Rear", 118.1, 9.6, 0, 250, "seat"),
        Station("Baggage", 142.8, 0, 0, 200, "cargo"),
    ),
    envelope=((83.0, 1650), (95.0, 1650), (95.0, 2440), (88.0, 2440), (83.0, 1950)),
    rotate_kts=60,
    approach_kts=70,
    max_flap_kts=100,
    visual=Visual("low", 1, 7.3, 9.1, (0.95, 0.95, 0.95), (0.1, 0.45, 0.2)),
    description="Low wing: better ground effect float, worse off-strip.",
    ground_roll_m=185,
)

C310 = AircraftSpec(
    key="c310",
    jsbsim_model="c310",
    name="Cessna 310 (twin)",
    price=240_000,
    mtow_lb=5500,
    stations=(
        Station("Nose baggage", -40, 0, 20, 350, "cargo"),
        Station("Pilot", 37, -14, 24, 250, "pilot"),
        Station("Co-pilot", 37, 14, 24, 250, "seat"),
        *_pairs("Row 2", 61, 14, 24, 250, "seat"),
        *_pairs("Row 3", 85, 14, 24, 250, "seat"),
        Station("Aft baggage", 110, 0, 24, 360, "cargo"),
    ),
    envelope=((38.0, 2950), (48.5, 2950), (48.5, 5500), (41.0, 5500), (38.0, 4000)),
    rotate_kts=85,
    approach_kts=95,
    max_flap_kts=140,
    visual=Visual("low", 2, 9.7, 11.3, (0.97, 0.97, 0.97), (0.6, 0.05, 0.05)),
    description="Fast twin with a nose locker. Hungry for runway.",
    toe_brake_steering=True,
    ground_roll_m=200,
    gear_limit_fpm=800,
)

DHC6 = AircraftSpec(
    key="dhc6",
    jsbsim_model="DHC6",
    name="DHC-6 Twin Otter",
    price=650_000,
    mtow_lb=12500,
    stations=(
        Station("Nose locker", 40, 0, 0, 500, "cargo"),
        Station("Pilot", 93.6, -18.2, 8.4, 250, "pilot"),
        Station("Co-pilot", 93.6, 18.2, 8.4, 250, "seat"),
        *_pairs("Row 1", 145, 16, 8, 250, "seat"),
        *_pairs("Row 2", 175, 16, 8, 250, "seat"),
        *_pairs("Row 3", 205, 16, 8, 250, "seat"),
        *_pairs("Row 4", 235, 16, 8, 250, "seat"),
        Station("Cabin cargo fwd", 160, 0, 0, 1200, "cargo"),
        Station("Cabin cargo aft", 265, 0, 0, 1200, "cargo"),
        Station("Aft locker", 330, 0, 10, 500, "cargo"),
    ),
    envelope=((206.0, 8000), (221.0, 8000), (221.0, 12500), (208.0, 12500)),
    rotate_kts=70,
    approach_kts=80,
    max_flap_kts=120,
    visual=Visual("high", 2, 15.8, 19.8, (0.95, 0.85, 0.2), (0.15, 0.15, 0.15)),
    description="STOL workhorse. Two tonnes of payload into a 300 m strip if you get the balance right.",
    ground_roll_m=290,
    gear_limit_fpm=900,
)

ROSTER: dict[str, AircraftSpec] = {a.key: a for a in (C172P, PA28, C182, C310, DHC6)}
