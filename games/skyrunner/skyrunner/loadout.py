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


FERRY_TANK_EMPTY_LB = 25.0


@dataclass
class Item:
    id: int
    label: str
    kind: str  # "passenger" | "cargo" | "tank"
    weight_lb: float
    job_id: int  # 0 = the aircraft's own equipment
    hot: bool = False  # contraband / fugitive -> police interest
    fragile: bool = False
    droppable: bool = False  # can be kicked out of the door in flight
    fuel_lb: float = 0.0  # ferry tanks only
    fuel_cap_lb: float = 0.0

    def set_fuel(self, lb: float) -> None:
        self.fuel_lb = max(0.0, min(self.fuel_cap_lb, lb))
        self.weight_lb = FERRY_TANK_EMPTY_LB + self.fuel_lb


def ferry_tank(item_id: int, capacity_lb: float) -> Item:
    return Item(item_id, "Ferry tank", "tank", FERRY_TANK_EMPTY_LB, 0, fuel_cap_lb=capacity_lb)


def load_time_s(item: Item) -> float:
    """Crew-seconds to move one item (walking a bladder tank in is slow too)."""
    return 4.0 + 0.02 * item.weight_lb


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
    # item id -> crew-seconds still needed before it's actually in its station
    pending: dict[int, float] = field(default_factory=dict)
    copilot_aboard: bool = False

    def station_weights(self, planned: bool = False) -> list[float]:
        """Weights actually in the aircraft (planned=True: as if loading were done)."""
        w = [0.0] * len(self.spec.stations)
        w[self.spec.pilot_station] = PILOT_LB
        if self.copilot_aboard:
            cp = self.copilot_station()
            if cp is not None:
                w[cp] += PILOT_LB
        for iid, st in self.assignment.items():
            if planned or iid not in self.pending:
                w[st] += self.items[iid].weight_lb
        return w

    def copilot_station(self) -> int | None:
        return next((i for i, s in enumerate(self.spec.stations) if s.name == "Co-pilot"), None)

    def ferry_capacity(self) -> float:
        """Bladder size: 80% of the wing tanks, but it has to fit on one cabin station."""
        biggest = max(s.max_lb for s in self.spec.stations if s.kind != "pilot")
        return round(min(self.mass.fuel_capacity_lb * 0.8, biggest - FERRY_TANK_EMPTY_LB))

    def ferry_tanks(self) -> list[Item]:
        return [i for i in self.items.values() if i.kind == "tank" and i.id in self.assignment and i.id not in self.pending]

    def ferry_fuel_lb(self) -> float:
        return sum(t.fuel_lb for t in self.ferry_tanks())

    def queue_move(self, item: Item) -> None:
        self.pending[item.id] = load_time_s(item)

    def work(self, dt: float, crew: int) -> list[int]:
        """Crew members each work one pending item. Returns ids that finished."""
        done = []
        for iid in list(self.pending)[:max(0, crew)]:
            self.pending[iid] -= dt
            if self.pending[iid] <= 0:
                del self.pending[iid]
                done.append(iid)
        return done

    def tank_fuel(self) -> list[float]:
        cap = self.mass.fuel_capacity_lb
        return [self.fuel_lb * c / cap for _, c in self.mass.tanks]

    def compute(self, fuel_lb: float | None = None, planned: bool = True) -> WBResult:
        """W&B of the plan (default) or of what is physically aboard (planned=False)."""
        fuel = self.fuel_lb if fuel_lb is None else fuel_lb
        w = self.mass.empty_lb
        m = w * self.mass.empty_cg_x_in
        for st, sw in zip(self.spec.stations, self.station_weights(planned)):
            w += sw
            m += sw * st.x_in
        cap = self.mass.fuel_capacity_lb
        for x, c in self.mass.tanks:
            f = fuel * c / cap
            w += f
            m += f * x
        cg = m / w
        overloads = [
            st.name for st, sw in zip(self.spec.stations, self.station_weights(planned)) if sw > st.max_lb
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
            self.remove_item(i.id)
        return gone

    def remove_item(self, item_id: int) -> Item | None:
        self.assignment.pop(item_id, None)
        self.pending.pop(item_id, None)
        return self.items.pop(item_id, None)

    def unassigned(self) -> list[Item]:
        return [i for i in self.items.values() if i.id not in self.assignment]

    def valid_stations(self, item: Item) -> list[int]:
        return [i for i, st in enumerate(self.spec.stations) if st.accepts(item.kind)]

    def seat_taken(self, st_idx: int, except_item: int | None = None) -> bool:
        if self.copilot_aboard and st_idx == self.copilot_station():
            return True
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
            self.pending.pop(item.id, None)
        else:
            self.assignment[item.id] = nxt
            self.queue_move(item)

    def all_loaded(self) -> bool:
        return not self.unassigned()

    def busy(self) -> bool:
        """Loading still in progress or items left on the ramp."""
        return bool(self.pending) or bool(self.unassigned())

    def auto_balance(self) -> bool:
        """Greedy loader: heaviest item first, pick the station that keeps the CG
        closest to the middle of the envelope without overloading a station.
        Returns True if everything found a place."""
        self.assignment.clear()
        target_w = min(self.compute().weight_lb + sum(i.weight_lb for i in self.items.values()), self.spec.mtow_lb)
        fwd, aft = cg_limits_at(target_w, self.spec.envelope)
        mid = (fwd + aft) / 2
        weights = self.station_weights(planned=True)
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

    def requeue_changed(self, before: dict[int, int]) -> None:
        """After an automatic re-plan, queue crew work for every item that moved."""
        for iid in [i for i in self.pending if i not in self.assignment]:
            del self.pending[iid]
        for iid, st in self.assignment.items():
            if before.get(iid) != st:
                self.queue_move(self.items[iid])
