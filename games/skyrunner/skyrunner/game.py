"""Game session: economy, jobs, loading, flight rules, police. No rendering
here, so the whole game loop can be driven headless (tests, bots, servers)."""
from __future__ import annotations

import json
import random
from dataclasses import dataclass, field
from pathlib import Path

from .aircraft import ROSTER, AircraftSpec
from .controls import ControlMapper, InputFrame
from .fdm import FlightModel, FlightState
from .jobs import Job, generate_jobs
from .jsbsim_patch import MassData, build_patched_root, read_mass_data
from .loadout import Loadout
from .police import PoliceSystem
from .world import AIRFIELD_BY_CODE, HALF, Airfield, World

FUEL_PRICE_PER_LB = 1.1
LOADMASTER_FEE = 150
START_MONEY = 3000
START_FIELD = "HAR"
OFF_FIELD_MAX_GS_KTS = 15.0


@dataclass
class FlightLog:
    departed_from: str | None = None
    airborne: bool = False
    max_bank: float = 0.0
    max_touchdown_fpm: float = 0.0
    last_touchdown_fpm: float = 0.0
    touchdowns_seen: int = 0


@dataclass
class Session:
    world: World = field(default_factory=World)
    seed: int = 1
    money: int = START_MONEY
    owned: set[str] = field(default_factory=lambda: {"c172p"})
    aircraft_key: str = "c172p"
    phase: str = "parked"  # parked | flying | crashed | busted
    location: str | None = START_FIELD
    messages: list[tuple[float, str]] = field(default_factory=list)
    active_jobs: list[Job] = field(default_factory=list)
    boards: dict[str, list[Job]] = field(default_factory=dict)
    jsbsim_root: str | None = None
    save_path: Path | None = None

    def __post_init__(self):
        self.rng = random.Random(self.seed)
        self.jsbsim_root = self.jsbsim_root or build_patched_root(list(ROSTER.values()))
        self._mass: dict[str, MassData] = {k: read_mass_data(s.jsbsim_model) for k, s in ROSTER.items()}
        self.police = PoliceSystem(self.world, random.Random(self.seed + 99))
        self.mapper = ControlMapper()
        self.log = FlightLog()
        self.time = 0.0
        self.fm: FlightModel | None = None
        self.loadout: Loadout | None = None
        self.state: FlightState | None = None
        self.last_outcome: str = ""
        self._switch_aircraft(self.aircraft_key, fuel_frac=0.6)
        self.spawn_at(self.location or START_FIELD)

    # ================================================================ helpers
    @property
    def spec(self) -> AircraftSpec:
        return ROSTER[self.aircraft_key]

    @property
    def airfield(self) -> Airfield | None:
        return AIRFIELD_BY_CODE.get(self.location) if self.location else None

    def say(self, text: str) -> None:
        self.messages.append((self.time, text))
        del self.messages[:-8]

    def carrying_hot(self) -> bool:
        return any(j.hot for j in self.active_jobs)

    def hot_value(self) -> int:
        return sum(j.payout for j in self.active_jobs if j.hot)

    @property
    def parked(self) -> bool:
        s = self.state
        return (
            self.phase == "parked"
            and s is not None
            and s.on_ground
            and s.gs_kts < 1.5
            and self.location is not None
        )

    # ================================================================ aircraft
    def _switch_aircraft(self, key: str, fuel_frac: float | None = None) -> None:
        spec = ROSTER[key]
        mass = self._mass[key]
        fuel = mass.fuel_capacity_lb * (fuel_frac if fuel_frac is not None else 0.5)
        self.aircraft_key = key
        self.loadout = Loadout(spec, mass, fuel_lb=fuel)
        self.fm = FlightModel(spec, self.jsbsim_root, mass)

    def spawn_at(self, code: str) -> None:
        af = AIRFIELD_BY_CODE[code]
        ux, uy = af.dir
        # line up on the runway, 25 m in from the threshold of end 0
        back = af.length / 2 - 25
        x, y = af.x - ux * back, af.y - uy * back
        self.fm.spawn(x, y, af.heading, self.world.airfield_elev(af), self.loadout)
        self.mapper.reset()
        self.location = code
        self.phase = "parked"
        self.log = FlightLog()
        self.state = self.fm.state()
        self.fm.controls.brake = 1.0
        if code not in self.boards:
            self.refresh_board(code)

    def refresh_board(self, code: str) -> None:
        af = AIRFIELD_BY_CODE[code]
        self.boards[code] = generate_jobs(af, self.world.airfields, self.rng, n=6)

    # ================================================================ ground ops
    def accept_job(self, job: Job) -> str | None:
        """Returns an error string, or None on success."""
        if not self.parked or self.location != job.origin:
            return "You need to be parked at the job's origin."
        seats = sum(1 for st in self.spec.stations if st.kind == "seat")
        pax_now = sum(1 for i in self.loadout.items.values() if i.kind == "passenger")
        pax_new = sum(1 for i in job.items if i.kind == "passenger")
        if pax_now + pax_new > seats:
            return f"Not enough seats ({seats} in a {self.spec.name})."
        job.accepted_at = self.time
        if job.kind == "fugitive":
            self.police.suspicion = max(self.police.suspicion, 60.0)  # already being looked for
        self.active_jobs.append(job)
        self.boards[job.origin].remove(job)
        for item in job.items:
            self.loadout.add(item)
        self._ramp_load(job)
        self.fm.apply_loadout(self.loadout)
        return None

    def _ramp_load(self, job: Job) -> None:
        """The ramp crew's idea of loading: first free spot from the front.
        Rarely what you want for the CG."""
        lo = self.loadout
        weights = lo.station_weights()
        for item in job.items:
            for s in sorted(lo.valid_stations(item), key=lambda i: lo.spec.stations[i].x_in):
                if lo.can_place(item, s) and weights[s] + item.weight_lb <= lo.spec.stations[s].max_lb:
                    lo.assignment[item.id] = s
                    weights[s] += item.weight_lb
                    break

    def drop_job(self, job: Job) -> None:
        if not self.parked or job not in self.active_jobs:
            return
        self.active_jobs.remove(job)
        self.loadout.remove_job(job.id)
        if self.location == job.origin:
            job.accepted_at = None
            self.boards.setdefault(job.origin, []).append(job)
        else:
            self.say(f"Dumped '{job.title}' at {self.location}. No pay.")
        self.fm.apply_loadout(self.loadout)

    def hire_loadmaster(self) -> bool:
        if not self.parked:
            return False
        self.money -= LOADMASTER_FEE
        ok = self.loadout.auto_balance()
        self.fm.apply_loadout(self.loadout)
        self.say(f"Loadmaster balanced the load (-${LOADMASTER_FEE})" + ("" if ok else " but some items don't fit!"))
        return ok

    def cycle_item(self, item_id: int, direction: int = 1) -> None:
        if not self.parked:
            return
        self.loadout.cycle(self.loadout.items[item_id], direction)
        self.fm.apply_loadout(self.loadout)

    def set_fuel(self, target_lb: float) -> None:
        if not self.parked:
            return
        lo = self.loadout
        cur = self.fm.fuel_lb()
        target = max(10.0, min(lo.mass.fuel_capacity_lb, target_lb))
        if target > cur:
            self.money -= int(round((target - cur) * FUEL_PRICE_PER_LB))
        lo.fuel_lb = target
        self.fm.apply_loadout(lo)

    def buy_or_switch(self, key: str) -> str | None:
        if not self.parked or not self.airfield or not self.airfield.shop:
            return "Aircraft dealers are only at Harbor Intl and Valley Regional."
        if self.active_jobs:
            return "Deliver or drop your current jobs first."
        spec = ROSTER[key]
        if key not in self.owned:
            if self.money < spec.price:
                return f"Need ${spec.price:,}."
            self.money -= spec.price
            self.owned.add(key)
            self.say(f"Bought a {spec.name}!")
        self._switch_aircraft(key)
        self.spawn_at(self.location)
        return None

    def respawn(self) -> None:
        """After a crash or bust."""
        code = self.log.departed_from or START_FIELD
        if self.phase == "busted":
            code = START_FIELD
        self.active_jobs.clear()
        self.loadout = Loadout(self.spec, self.loadout.mass, fuel_lb=self.loadout.mass.fuel_capacity_lb * 0.5)
        self.police.reset()
        self.spawn_at(code)

    # ================================================================ tick
    def update(self, dt: float, inp: InputFrame) -> None:
        self.time += dt
        if self.phase in ("crashed", "busted"):
            if "confirm" in inp.pressed:
                self.respawn()
            return
        controls = self.mapper.update(dt, inp)
        if self.parked and not ({"throttle_up", "brake"} & inp.held) and controls.throttle < 0.05:
            controls.brake = 1.0  # parking brake while in menus
        if self.phase == "parked" and self.loadout.unassigned() and controls.throttle > 0.05:
            controls.throttle = 0.0
            controls.brake = 1.0
            if not self.messages or self.time - self.messages[-1][0] > 4:
                self.say("Cargo still on the ramp! Load it [L] or drop the job [J].")
        self.fm.controls = controls
        s = self.fm.step(dt, self.world.ground)
        self.state = s
        if s.valid:
            self.loadout.fuel_lb = s.fuel_lb
        self._rules(dt, s)
        for e in self.police.events:
            self.say(e)
        self.police.events.clear()

    def _crash(self, reason: str) -> None:
        self.phase = "crashed"
        fee = max(2500, int(self.spec.price * 0.12))
        self.money -= fee
        lost = len(self.active_jobs)
        self.last_outcome = f"CRASH: {reason}. Repairs -${fee:,}." + (f" {lost} job(s) lost." if lost else "")
        self.say(self.last_outcome)

    def _bust(self, how: str) -> None:
        self.phase = "busted"
        fine = 1500 + int(max(0, self.money) * 0.25)
        self.money -= fine
        self.last_outcome = f"BUSTED ({how}). Fine and impound -${fine:,}. Cargo seized."
        self.say(self.last_outcome)

    def _rules(self, dt: float, s: FlightState) -> None:
        fm, log = self.fm, self.log
        if fm.crash_reason:
            return self._crash(fm.crash_reason)
        if not s.valid:
            return self._crash("Airframe failure")
        af_here = self.world.airfield_at(s.x, s.y, margin=4.0)

        # --- leaving / flying
        if not s.on_ground and s.agl > 3.0:
            if not log.airborne:
                log.airborne = True
                log.departed_from = log.departed_from or self.location
            if self.phase == "parked":
                self.phase = "flying"
                self.location = None
            log.max_bank = max(log.max_bank, abs(s.roll))
        elif self.phase == "parked" and s.gs_kts > 3:
            log.departed_from = log.departed_from or self.location

        # --- collisions
        if self.world.tree_hit(s.x, s.y, s.alt - fm.mass.gear_height_ft * 0.3048, radius=4.0):
            return self._crash("Hit trees")
        if abs(s.x) > HALF + 3000 or abs(s.y) > HALF + 3000:
            self.say("Leaving the operating area - turn back!")

        # --- touchdowns
        if fm.touchdowns != log.touchdowns_seen:
            log.touchdowns_seen = fm.touchdowns
            fpm = -fm.last_touchdown_fpm
            log.last_touchdown_fpm = fpm
            log.max_touchdown_fpm = max(log.max_touchdown_fpm, fpm)
            limit = self.spec.gear_limit_fpm * (0.75 if self.loadout.compute().overweight_lb > 0 else 1.0)
            if fpm > limit:
                return self._crash(f"Gear collapsed on a {fpm:.0f} fpm touchdown")
            if log.airborne:
                self.say(f"Touchdown {fpm:.0f} fpm" + (" - butter!" if fpm < 150 else ""))

        if s.on_ground:
            if self.world.is_water(s.x, s.y) and af_here is None:
                return self._crash("Ditched in the sea")
            if abs(s.roll) > 12:
                return self._crash("Wingtip strike")
            if s.pitch < -7:
                return self._crash("Prop strike - nosed over")
            if af_here is None and s.gs_kts > OFF_FIELD_MAX_GS_KTS:
                return self._crash("Ran off the strip into rough ground")
            if s.gs_kts < 1.0 and af_here is not None and log.airborne:
                self._arrive(af_here, s)

        # --- police / rivals
        if self.phase == "flying":
            outcome = self.police.update(dt, s, self.carrying_hot(), self.hot_value())
            if outcome == "busted":
                return self._bust("forced down by police")
            if outcome == "hijacked":
                lost = [j for j in self.active_jobs if j.hot]
                for j in lost:
                    self.active_jobs.remove(j)
                    self.loadout.remove_job(j.id)
                self.fm.apply_loadout(self.loadout)
                self.say("Rivals forced you to jettison the goods!")

    def _arrive(self, af: Airfield, s: FlightState) -> None:
        self.phase = "parked"
        self.location = af.code
        if self.police.landing_check(s, af, self.carrying_hot()):
            return self._bust(f"arrested on landing at {af.name}")
        delivered = [j for j in self.active_jobs if j.dest == af.code]
        for job in delivered:
            pay, notes = self._grade(job)
            self.money += pay
            self.active_jobs.remove(job)
            self.loadout.remove_job(job.id)
            self.say(f"Delivered '{job.title}': +${pay:,} {notes}".rstrip())
        self.fm.apply_loadout(self.loadout)
        self.police.reset(keep_wanted=True)
        self.log = FlightLog()
        self.refresh_board(af.code)
        if not delivered:
            self.say(f"Parked at {af.name}.")
        self.save()

    def _grade(self, job: Job) -> tuple[int, str]:
        pay = float(job.payout)
        notes = []
        log = self.log
        left = job.time_left(self.time)
        if left is not None and left < 0:
            pay *= 0.4
            notes.append("(late)")
        if any(i.fragile for i in job.items) and log.max_touchdown_fpm > 400:
            pay *= 0.5
            notes.append("(breakage)")
        if job.comfort and (log.max_bank > 45 or log.max_touchdown_fpm > 300):
            pay *= 0.7
            notes.append("(VIP unhappy)")
        if log.last_touchdown_fpm < 150:
            pay *= 1.1
            notes.append("(smooth landing bonus)")
        return int(pay), " ".join(notes)

    # ================================================================ persistence
    def save(self) -> None:
        if not self.save_path:
            return
        self.save_path.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "money": self.money,
            "owned": sorted(self.owned),
            "aircraft": self.aircraft_key,
            "location": self.location if self.parked else (self.log.departed_from or START_FIELD),
        }
        self.save_path.write_text(json.dumps(data, indent=2))

    @classmethod
    def load_or_new(cls, save_path: Path, **kw) -> "Session":
        data = {}
        if save_path.exists():
            try:
                data = json.loads(save_path.read_text())
            except (OSError, ValueError):
                data = {}
        sess = cls(
            money=data.get("money", START_MONEY),
            owned=set(data.get("owned", ["c172p"])) & set(ROSTER) or {"c172p"},
            aircraft_key=data.get("aircraft", "c172p") if data.get("aircraft") in ROSTER else "c172p",
            location=data.get("location", START_FIELD) if data.get("location") in AIRFIELD_BY_CODE else START_FIELD,
            save_path=save_path,
            **kw,
        )
        return sess
