"""Weight & balance.

The numbers computed here are a *prediction* shown in the load planner. What the
aircraft actually does is decided by JSBSim, which receives the same masses as
point masses at the same arms, so a bad load really flies badly.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .aircraft import AircraftSpec
from .jsbsim_patch import MassData

PILOT_LB = 180.0


@dataclass
class Item:
    id: int
    label: str
    kind: str  # "passenger" | "cargo"
    weight_lb: float
    job_id: int
    hot: bool = False  # contraband / fugitive -> police interest
    fragile: bool = False


@dataclass
class WBResult:
    weight_lb: float
    cg_in: float
    in_envelope: bool
    overweight_lb: float
    station_overloads: list[str]
    fwd_limit_in: float
    aft_limit_in: float

    @property
    def ok(self) -> bool:
        return self.in_envelope and self.overweight_lb <= 0 and not self.station_overloads


def point_in_polygon(x: float, y: float, poly) -> bool:
    inside = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if (y1 > y) != (y2 > y):
            xin = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if x < xin:
                inside = not inside
    return inside


def cg_limits_at(weight: float, poly) -> tuple[float, float]:
    """Forward/aft CG limit at a weight: intersect the envelope with a horizontal line."""
    xs = []
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        lo, hi = min(y1, y2), max(y1, y2)
        if lo <= weight <= hi and y1 != y2:
            xs.append(x1 + (weight - y1) * (x2 - x1) / (y2 - y1))
    if not xs:
        return float("nan"), float("nan")
    return min(xs), max(xs)


@dataclass
class Loadout:
    spec: AircraftSpec
    mass: MassData
    fuel_lb: float
    assignment: dict[int, int] = field(default_factory=dict)  # item id -> station idx
    items: dict[int, Item] = field(default_factory=dict)

    def station_weights(self) -> list[float]:
        w = [0.0] * len(self.spec.stations)
        w[self.spec.pilot_station] = PILOT_LB
        for iid, st in self.assignment.items():
            w[st] += self.items[iid].weight_lb
        return w

    def tank_fuel(self) -> list[float]:
        cap = self.mass.fuel_capacity_lb
        return [self.fuel_lb * c / cap for _, c in self.mass.tanks]

    def compute(self, fuel_lb: float | None = None) -> WBResult:
        fuel = self.fuel_lb if fuel_lb is None else fuel_lb
        w = self.mass.empty_lb
        m = w * self.mass.empty_cg_x_in
        for st, sw in zip(self.spec.stations, self.station_weights()):
            w += sw
            m += sw * st.x_in
        cap = self.mass.fuel_capacity_lb
        for x, c in self.mass.tanks:
            f = fuel * c / cap
            w += f
            m += f * x
        cg = m / w
        overloads = [
            st.name for st, sw in zip(self.spec.stations, self.station_weights()) if sw > st.max_lb
        ]
        fwd, aft = cg_limits_at(min(max(w, self.spec.envelope[0][1]), self.spec.mtow_lb), self.spec.envelope)
        return WBResult(
            weight_lb=w,
            cg_in=cg,
            in_envelope=point_in_polygon(cg, min(w, self.spec.mtow_lb - 1e-6), self.spec.envelope)
            and w >= self.spec.envelope[0][1],
            overweight_lb=max(0.0, w - self.spec.mtow_lb),
            station_overloads=overloads,
            fwd_limit_in=fwd,
            aft_limit_in=aft,
        )

    # -- editing ---------------------------------------------------------
    def add(self, item: Item) -> None:
        self.items[item.id] = item

    def remove_job(self, job_id: int) -> list[Item]:
        gone = [i for i in self.items.values() if i.job_id == job_id]
        for i in gone:
            self.items.pop(i.id)
            self.assignment.pop(i.id, None)
        return gone

    def unassigned(self) -> list[Item]:
        return [i for i in self.items.values() if i.id not in self.assignment]

    def valid_stations(self, item: Item) -> list[int]:
        return [i for i, st in enumerate(self.spec.stations) if st.accepts(item.kind)]

    def seat_taken(self, st_idx: int, except_item: int | None = None) -> bool:
        return any(
            s == st_idx and self.items[i].kind == "passenger" and i != except_item
            for i, s in self.assignment.items()
        )

    def can_place(self, item: Item, st_idx: int) -> bool:
        st = self.spec.stations[st_idx]
        if not st.accepts(item.kind):
            return False
        if self.seat_taken(st_idx, item.id):
            return False  # one passenger per seat, nothing on top of them
        if item.kind == "passenger" and any(
            s == st_idx and i != item.id for i, s in self.assignment.items()
        ):
            return False
        return True

    def cycle(self, item: Item, direction: int = 1) -> None:
        """Move an item to the next station that will take it (or unload it)."""
        options = [None] + [s for s in self.valid_stations(item) if self.can_place(item, s)]
        cur = self.assignment.get(item.id)
        idx = options.index(cur) if cur in options else 0
        nxt = options[(idx + direction) % len(options)]
        if nxt is None:
            self.assignment.pop(item.id, None)
        else:
            self.assignment[item.id] = nxt

    def all_loaded(self) -> bool:
        return not self.unassigned()

    def auto_balance(self) -> bool:
        """Greedy loader: heaviest item first, pick the station that keeps the CG
        closest to the middle of the envelope without overloading a station.
        Returns True if everything found a place."""
        self.assignment.clear()
        target_w = min(self.compute().weight_lb + sum(i.weight_lb for i in self.items.values()), self.spec.mtow_lb)
        fwd, aft = cg_limits_at(target_w, self.spec.envelope)
        mid = (fwd + aft) / 2
        weights = self.station_weights()
        for item in sorted(self.items.values(), key=lambda i: -i.weight_lb):
            best, best_err = None, None
            for s in self.valid_stations(item):
                if not self.can_place(item, s):
                    continue
                if weights[s] + item.weight_lb > self.spec.stations[s].max_lb:
                    continue
                self.assignment[item.id] = s
                err = abs(self.compute().cg_in - mid)
                del self.assignment[item.id]
                if best_err is None or err < best_err:
                    best, best_err = s, err
            if best is not None:
                self.assignment[item.id] = best
                weights[best] += item.weight_lb
        return self.all_loaded()
