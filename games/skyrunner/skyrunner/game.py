"""Game session: the authoritative simulation for one match.

It holds the runner crew's aircraft (JSBSim), the task force, boats, AI runs,
jobs and economy. Every action goes through `command(role, name, **args)` so
local menus, network clients and AI crew obey the same rules. There is no
rendering in here, so the whole game loop runs headless (tests, bots,
dedicated servers).
"""
from __future__ import annotations

import json
import math
import random
from dataclasses import dataclass, field
from pathlib import Path

from .ai_smuggler import AISmuggler, SmugglerDirector, entry_and_exit
from .aircraft import ROSTER, AircraftSpec
from .autopilot import Autopilot
from .comms import RadioNet
from .controls import ControlMapper, InputFrame
from .events import EventBus
from .fdm import FT, FlightModel, FlightState
from .jobs import Job, generate_jobs, new_id
from .jsbsim_patch import MassData, build_patched_root, read_mass_data
from .loadout import Loadout, ferry_tank
from .maritime import Maritime, random_drop_point
from .police import LAW_FEATURES, PoliceSystem, Target, Tip
from .roles import MODE_ROLES, Mode, Role, allowed
from .sensors import Signature
from .world import AIRFIELD_BY_CODE, HALF, Airfield, World

FUEL_PRICE_PER_LB = 1.1
LOADMASTER_FEE = 150
START_MONEY = 3000
START_FIELD = "HAR"
OFF_FIELD_MAX_GS_KTS = 15.0
KICK_MAX_KTS = 130.0
KICK_TIME = {"copilot": 2.0, "pilot": 4.0}
PUMP_RATE_LB_MIN = {"copilot": 60.0, "pilot": 25.0}
SPOTTER_FEE = 400
SPOTTER_RANGE_M = 5000.0
SPOTTER_DELAY_S = 5.0
SPOTTER_MOVE_S = 60.0
INFORMANT_BASE = 0.30
SPOTTER_LEAK = 0.15
FERRY_FUEL_TIP = 0.25
GEAR = {
    "scanner": (1800, "Radio scanner: hear police dispatch (unless encrypted)"),
    "detector": (2500, "Radar detector: warns when a radar paints you"),
    "ferry_tank": (3000, "Ferry bladder tank: extra fuel in the cabin"),
}
RUNNER_FEATURES = {"contraband", "airdrop", "ferry", "scanner", "detector", "spotters", "copilot"}
SANDBOX_FEATURES = RUNNER_FEATURES | {"interceptors", "rivals", "informants", "cutters", "df"}


@dataclass
class FlightLog:
    departed_from: str | None = None
    airborne: bool = False
    max_bank: float = 0.0
    max_touchdown_fpm: float = 0.0
    last_touchdown_fpm: float = 0.0
    touchdowns_seen: int = 0


@dataclass
class Spotter:
    code: str
    moving_to: str | None = None
    move_t: float = 0.0
    last_report_t: float = -1e9


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
    mode: Mode = Mode.SOLO
    features: set[str] | None = None
    humans: dict[Role, str] = field(default_factory=dict)
    gear: set[str] = field(default_factory=set)

    def __post_init__(self):
        self.mode = Mode(self.mode)
        if self.features is None:
            self.features = set(LAW_FEATURES) if self.mode == Mode.POLICE else set(SANDBOX_FEATURES)
        self.rng = random.Random(self.seed)
        self.jsbsim_root = self.jsbsim_root or build_patched_root(list(ROSTER.values()))
        self._mass: dict[str, MassData] = {k: read_mass_data(s.jsbsim_model) for k, s in ROSTER.items()}
        self.bus = EventBus()
        self.radio = RadioNet(random.Random(self.seed + 7))
        self.police = PoliceSystem(self.world, random.Random(self.seed + 99), radio=self.radio,
                                   controller="human" if Role.CONTROLLER in self.humans else "ai",
                                   features=self.features & LAW_FEATURES)
        self.radio.df_stations = [(a.code, a.x, a.y) for a in self.world.airfields if a.police]
        self.radio.df_enabled = "df" in self.features
        self.maritime = Maritime(self.world, random.Random(self.seed + 13))
        self.smugglers: list[AISmuggler] = []
        self.director = SmugglerDirector(random.Random(self.seed + 21))
        self.mapper = ControlMapper()
        self.autopilot = Autopilot()
        self.log = FlightLog()
        self.time = 0.0
        self.fm: FlightModel | None = None
        self.loadout: Loadout | None = None
        self.state: FlightState | None = None
        self.last_outcome: str = ""
        self.law_log: list[tuple[float, str]] = []
        self.scanner_log: list[tuple[float, str]] = []
        self.intel: dict[str, tuple[float, float, float, str]] = {}  # unit -> (t, x, y, source)
        self.spotters: list[Spotter] = []
        self.transponder = True
        self.squawk = f"N{self.rng.randint(100, 999)}{self.rng.choice('ABCDEFGHJK')}"
        self.kick_queue = 0
        self.kick_t = 0.0
        self.kicker: str | None = None
        self.auto_kick = True
        self.pumping = False
        self.copilot: str | None = "human" if Role.COPILOT in self.humans else None
        self.campaign = None  # set by campaign.Campaign.attach
        self.runner_score = {"bales_delivered": 0, "escapes": 0}
        self.fuel_caches: dict[str, float] = {}  # shady strips: fuel you flew in yourself
        self._scanner_seen = 0.0
        self._switch_aircraft(self.aircraft_key, fuel_frac=0.6)
        self.spawn_at(self.location or START_FIELD)
        if self.police.controller == "ai":
            if "aerostat" in self.features:
                self.police.set_aerostat(True)
            if "encryption" in self.features:
                self.police.set_encryption(True)

    # ================================================================ helpers
    @property
    def runner_active(self) -> bool:
        return self.mode != Mode.POLICE

    @property
    def spec(self) -> AircraftSpec:
        return ROSTER[self.aircraft_key]

    @property
    def airfield(self) -> Airfield | None:
        return AIRFIELD_BY_CODE.get(self.location) if self.location else None

    def say(self, text: str) -> None:
        self.messages.append((self.time, text))
        del self.messages[:-8]

    def law_say(self, text: str) -> None:
        self.law_log.append((self.time, text))
        del self.law_log[:-40]

    def carrying_hot(self) -> bool:
        return any(i.hot for i in self.loadout.items.values())

    def hot_value(self) -> int:
        return sum(j.payout for j in self.active_jobs if j.hot)

    def job_xy(self, job: Job) -> tuple[float, float]:
        return job.target_xy(AIRFIELD_BY_CODE)

    def find_job(self, job_id: int) -> Job | None:
        for j in self.active_jobs:
            if j.id == job_id:
                return j
        for board in self.boards.values():
            for j in board:
                if j.id == job_id:
                    return j
        return None

    @property
    def parked(self) -> bool:
        s = self.state
        return (
            self.runner_active
            and self.phase == "parked"
            and s is not None
            and s.on_ground
            and s.gs_kts < 1.5
            and self.location is not None
        )

    def crew_count(self) -> int:
        n = 1 + (1 if self.copilot else 0)
        if self.airfield and self.airfield.kind in ("hub", "regional"):
            n += 2  # ramp crew
        return n

    def range_estimate(self) -> tuple[float, float]:
        """(endurance hours, still-air range km) from live fuel flow incl. ferry fuel."""
        s = self.state
        if s is None or s.fuel_flow_pph < 1.0:
            return 0.0, 0.0
        fuel = s.fuel_lb + self.loadout.ferry_fuel_lb()
        hours = fuel / s.fuel_flow_pph
        return hours, hours * max(s.gs_kts, 1.0) * 1.852

    # ================================================================ aircraft
    def _switch_aircraft(self, key: str, fuel_frac: float | None = None) -> None:
        spec = ROSTER[key]
        mass = self._mass[key]
        fuel = mass.fuel_capacity_lb * (fuel_frac if fuel_frac is not None else 0.5)
        self.aircraft_key = key
        self.loadout = Loadout(spec, mass, fuel_lb=fuel, copilot_aboard=bool(self.copilot))
        self.fm = FlightModel(spec, self.jsbsim_root, mass)

    def spawn_at(self, code: str) -> None:
        af = AIRFIELD_BY_CODE[code]
        ux, uy = af.dir
        back = af.length / 2 - 25  # line up 25 m in from the threshold of end 0
        x, y = af.x - ux * back, af.y - uy * back
        self.fm.spawn(x, y, af.heading, self.world.airfield_elev(af), self.loadout)
        self.fm.controls.brake = 1.0
        self.fm.step(0.5, self.world.ground)  # settle onto the gear
        self._after_spawn()
        self.location = code
        self.phase = "parked"
        if code not in self.boards:
            self.refresh_board(code)

    def spawn_airborne(self, x: float, y: float, heading: float, alt_agl: float, speed_kts: float) -> None:
        """Start in the air (offshore entry for long runs)."""
        self.fm.spawn(x, y, heading, 0.0, self.loadout,
                      airborne_alt_m=self.world.ground(x, y) + alt_agl, speed_kts=speed_kts)
        self._after_spawn()
        self.mapper.controls.throttle = 0.75
        self.fm.controls.brake = 0.0
        self.location = None
        self.phase = "flying"
        self.log.airborne = True

    def _after_spawn(self) -> None:
        self.mapper.reset()
        self.autopilot.disengage()
        self.kick_queue = 0
        self.pumping = False
        self.log = FlightLog()
        self.state = self.fm.state()
        self.fm.controls.brake = 1.0

    def refresh_board(self, code: str) -> None:
        af = AIRFIELD_BY_CODE[code]
        self.boards[code] = generate_jobs(
            af, self.world.airfields, self.rng, n=6, features=self.features,
            drop_point_fn=lambda: random_drop_point(self.world, self.rng, near=self.maritime.cove),
        )

    # ================================================================ commands
    def command(self, role: Role | str, name: str, /, **args) -> tuple[bool, str]:
        """The single entry point for every non-flight action."""
        role = Role(role)
        if not allowed(role, name):
            return False, f"{role.value} can't do '{name}'."
        handler = getattr(self, f"_cmd_{name}", None)
        if handler is None:
            return False, f"Unknown command {name}."
        try:
            err = handler(role, **args)
        except (TypeError, ValueError, KeyError) as e:
            return False, f"Bad arguments for {name}: {e}"
        if err:
            return False, err
        return True, "ok"

    def _cmd_accept_job(self, role, job_id: int):
        job = self.find_job(int(job_id))
        return self.accept_job(job) if job else "No such job."

    def _cmd_drop_job(self, role, job_id: int):
        job = self.find_job(int(job_id))
        if job is None:
            return "No such job."
        self.drop_job(job)

    def _cmd_move_item(self, role, item_id: int, direction: int = 1):
        if not self.parked:
            return "Loading happens on the ground, stopped."
        if int(item_id) not in self.loadout.items:
            return "No such item."
        self.cycle_item(int(item_id), int(direction))

    def _cmd_loadmaster(self, role):
        return None if self.hire_loadmaster() else "Loadmaster couldn't fit everything."

    def _cmd_set_fuel(self, role, lb: float):
        if not self.parked:
            return "Refuel on the ground."
        self.set_fuel(float(lb))

    def _cmd_fill_ferry(self, role, lb: float):
        return self.fill_ferry(float(lb))

    def _cmd_buy_aircraft(self, role, key: str):
        return self.buy_or_switch(key)

    def _cmd_buy_gear(self, role, name: str):
        return self.buy_gear(name)

    def _cmd_hire_spotter(self, role, code: str | None = None):
        return self.hire_spotter(code or self.location)

    def _cmd_spotter_move(self, role, code: str, index: int = 0):
        if code not in AIRFIELD_BY_CODE or not self.spotters:
            return "No spotter / unknown field."
        sp = self.spotters[min(int(index), len(self.spotters) - 1)]
        sp.moving_to, sp.move_t = code, SPOTTER_MOVE_S
        self.say(f"Spotter heading to {AIRFIELD_BY_CODE[code].name} (60 s)")

    def _cmd_transponder(self, role, on: bool | None = None):
        self.transponder = (not self.transponder) if on is None else bool(on)
        self.say(f"Transponder {'ON, squawking ' + self.squawk if self.transponder else 'OFF'}")

    def _cmd_autopilot(self, role, on: bool | None = None):
        on = (not self.autopilot.engaged) if on is None else bool(on)
        if on:
            if self.state is None or self.state.on_ground:
                return "Autopilot needs to be airborne."
            self.autopilot.engage(self.state, self.fm.controls.elevator)
            self.autopilot.min_ias_kts = self.spec.approach_kts * 1.05
            self.say(f"Autopilot ON: holding {self.state.alt / FT:.0f} ft, heading {self.state.heading:.0f}")
        else:
            self.autopilot.disengage()
            self.say("Autopilot OFF")

    def _cmd_kick(self, role, count: int = 1):
        return self.request_kick(role, int(count))

    def _cmd_auto_kick(self, role, on: bool | None = None):
        self.auto_kick = (not self.auto_kick) if on is None else bool(on)

    def _cmd_pump(self, role, on: bool | None = None):
        if not self.loadout.ferry_tanks():
            return "No ferry tank aboard."
        self.pumping = (not self.pumping) if on is None else bool(on)
        self.say(f"Ferry pump {'ON' if self.pumping else 'OFF'}")

    def _cmd_call_boat(self, role):
        return self.call_boat()

    def _cmd_boat_goto(self, role, x: float, y: float):
        boats = [b for b in self.maritime.boats if b.kind == "gofast" and b.state not in ("seized", "delivered")]
        if not boats:
            return "No boat at sea."
        boats[0].goal, boats[0].state = (float(x), float(y)), "to_rendezvous"

    def _cmd_confirm(self, role):
        if self.phase in ("crashed", "busted"):
            self.respawn()

    def _cmd_chat(self, role, text: str):
        text = str(text)[:200]
        if role.side.value == "runner":
            self.say(f"[{role.value}] {text}")
        else:
            self.law_say(f"[{role.value}] {text}")

    # law side
    def _cmd_launch(self, role, kind: str, base: str | None = None, x: float | None = None, y: float | None = None):
        goal = (float(x), float(y)) if x is not None and y is not None else None
        if kind == "cutter":
            if "cutters" not in self.features:
                return "No cutter assigned."
            if self.police.stock.get("cutter", 0) <= 0:
                return "No cutter available."
            self.police.stock["cutter"] -= 1
            c = self.maritime.new_cutter(goal)
            self.radio.transmit(self.time, "police", c.id, "underway from the harbor", (c.x, c.y))
            return None
        return self.police.launch(kind, base, goal=goal)

    def _cmd_dispatch(self, role, unit: str, target: str | None = None, x: float | None = None, y: float | None = None):
        point = (float(x), float(y)) if x is not None and y is not None else None
        target = self.police.resolve(target)
        boat = self.maritime.boat(unit)
        if boat is not None and boat.kind == "cutter":
            if point is None and target:
                tr = self.police.sensors.tracks.get(target)
                point = (tr.x, tr.y) if tr else None
            if point is None:
                return "Cutters need a point."
            boat.goal, boat.state = point, "patrol"
            return None
        return self.police.dispatch(unit, target, point)

    def _cmd_recall(self, role, unit: str):
        boat = self.maritime.boat(unit)
        if boat is not None and boat.kind == "cutter":
            boat.state, boat.goal = "return", None
            return None
        return self.police.recall(unit)

    def _cmd_encrypt(self, role, on: bool = True):
        return self.police.set_encryption(bool(on))

    def _cmd_aerostat(self, role, on: bool = True):
        return self.police.set_aerostat(bool(on))

    # ================================================================ ground ops
    def accept_job(self, job: Job) -> str | None:
        """Returns an error string, or None on success."""
        if not self.parked or self.location != job.origin:
            return "You need to be parked at the job's origin."
        if job.hot and "contraband" not in self.features:
            return "Not that kind of pilot. Yet."
        seats = sum(1 for st in self.spec.stations if st.kind == "seat") - (1 if self.copilot else 0)
        pax_now = sum(1 for i in self.loadout.items.values() if i.kind == "passenger")
        pax_new = sum(1 for i in job.items if i.kind == "passenger")
        if pax_now + pax_new > seats:
            return f"Not enough seats ({seats} free in a {self.spec.name})."
        job.accepted_at = self.time
        if job.kind == "fugitive":
            self.police.suspicion = max(self.police.suspicion, 60.0)  # already being looked for
        self.active_jobs.append(job)
        self.boards[job.origin].remove(job)
        for item in job.items:
            self.loadout.add(item)
        self._ramp_load(job)
        self.fm.apply_loadout(self.loadout)
        if job.is_airdrop:
            boat = self.maritime.new_gofast(job.drop_point, job.id)
            job.boat_id = boat.id
            self.say(f"{boat.id} is heading out to the rendezvous.")
        if job.hot:
            self._informant_roll(job)
        self.bus.emit("job_accepted", self.time, audience=("runner",), job_id=job.id, hot=job.hot)
        return None

    def _informant_roll(self, job: Job) -> None:
        if "informants" not in self.features:
            return
        chance = 1 - (1 - INFORMANT_BASE) * (1 - SPOTTER_LEAK) ** len(self.spotters)
        if self.rng.random() < chance:
            x, y = self.job_xy(job)
            x += self.rng.uniform(-1500, 1500)
            y += self.rng.uniform(-1500, 1500)
            where = "a drop at sea" if job.is_airdrop else AIRFIELD_BY_CODE[job.dest].name
            self.police.add_tip(x, y, 3000, f"informant: load moving tonight, {where}, aircraft {self.squawk}",
                                squawk=self.squawk, target_id="runner")

    def _ramp_load(self, job: Job) -> None:
        """The ramp crew's idea of loading: first free spot from the front.
        Rarely what you want for the CG."""
        lo = self.loadout
        weights = lo.station_weights(planned=True)
        for item in job.items:
            for s in sorted(lo.valid_stations(item), key=lambda i: lo.spec.stations[i].x_in):
                if lo.can_place(item, s) and weights[s] + item.weight_lb <= lo.spec.stations[s].max_lb:
                    lo.assignment[item.id] = s
                    lo.queue_move(item)
                    weights[s] += item.weight_lb
                    break

    def drop_job(self, job: Job) -> None:
        if not self.parked or job not in self.active_jobs:
            return
        self.active_jobs.remove(job)
        self.loadout.remove_job(job.id)
        if job.boat_id:
            boat = self.maritime.boat(job.boat_id)
            if boat:
                self.maritime.boats.remove(boat)
        if self.location == job.origin:
            job.accepted_at = None
            job.boat_id = None
            self.boards.setdefault(job.origin, []).append(job)
        else:
            self.say(f"Dumped '{job.title}' at {self.location}. No pay.")
        self.fm.apply_loadout(self.loadout)

    def hire_loadmaster(self) -> bool:
        if not self.parked:
            return False
        self.money -= LOADMASTER_FEE
        before = dict(self.loadout.assignment)
        ok = self.loadout.auto_balance()
        self.loadout.requeue_changed(before)
        self.fm.apply_loadout(self.loadout)
        self.say(f"Loadmaster re-planned the load (-${LOADMASTER_FEE})" + ("" if ok else " but some items don't fit!"))
        return ok

    def cycle_item(self, item_id: int, direction: int = 1) -> None:
        if not self.parked:
            return
        self.loadout.cycle(self.loadout.items[item_id], direction)
        self.fm.apply_loadout(self.loadout)

    def fuel_source(self) -> tuple[float, float]:
        """(price per lb, lb available) at the current field."""
        af = self.airfield
        if af is None:
            return FUEL_PRICE_PER_LB, 0.0
        cache = self.fuel_caches.get(af.code, 0.0)
        if af.kind in ("hub", "regional"):
            return FUEL_PRICE_PER_LB, 1e9
        if af.kind == "bush":
            return FUEL_PRICE_PER_LB * 2, 1e9 if cache <= 0 else cache  # farmer's drums, or your cache
        return (0.0, cache) if cache > 0 else (0.0, 0.0)  # shady strips: only what you flew in

    def _draw_fuel(self, want_lb: float) -> float:
        """Take fuel from the field's supply; returns what you got (and charges for it)."""
        price, avail = self.fuel_source()
        code = self.location
        cache = self.fuel_caches.get(code, 0.0)
        got = min(want_lb, avail)
        if cache > 0:
            self.fuel_caches[code] = cache - min(got, cache)
            price = 0.0
        self.money -= int(round(got * price))
        return got

    def set_fuel(self, target_lb: float) -> None:
        if not self.parked:
            return
        lo = self.loadout
        cur = self.fm.fuel_lb()
        target = max(10.0, min(lo.mass.fuel_capacity_lb, target_lb))
        if target > cur:
            target = cur + self._draw_fuel(target - cur)
            if target <= cur + 0.5:
                self.say("No fuel for sale here - fly drums in to build a cache.")
        lo.fuel_lb = target
        self.fm.apply_loadout(lo)

    def fill_ferry(self, lb: float) -> str | None:
        if not self.parked:
            return "Refuel on the ground."
        tanks = self.loadout.ferry_tanks()
        if not tanks:
            return "No ferry tank installed."
        t = tanks[0]
        before = t.fuel_lb
        want = max(0.0, min(t.fuel_cap_lb, lb) - before)
        got = self._draw_fuel(want) if want > 0 else 0.0
        t.set_fuel(before + got if want > 0 else lb)
        if want > 0 and got <= 0.5:
            return "No fuel for sale here."
        if t.fuel_lb > before:
            af = self.airfield
            if af and af.police and "informants" in self.features and self.rng.random() < FERRY_FUEL_TIP:
                self.police.add_tip(af.x, af.y, 20000, f"fuel desk: {self.squawk} bought ferry fuel at {af.name}",
                                    squawk=self.squawk, target_id="runner")
        self.fm.apply_loadout(self.loadout)
        return None

    def buy_gear(self, name: str) -> str | None:
        if name not in GEAR:
            return "Unknown gear."
        price, _ = GEAR[name]
        feature = {"ferry_tank": "ferry"}.get(name, name)
        if feature not in self.features:
            return "Nobody on the island sells that yet."
        if not self.parked:
            return "Buy gear on the ground."
        if name == "ferry_tank":
            if any(i.kind == "tank" for i in self.loadout.items.values()):
                return "Already have a ferry tank."
            tank = ferry_tank(new_id(), self.loadout.ferry_capacity())
            self.loadout.add(tank)
            spot = next((s for s in sorted(self.loadout.valid_stations(tank),
                                           key=lambda i: -self.spec.stations[i].x_in)
                         if self.loadout.can_place(tank, s)), None)
            if spot is not None:
                self.loadout.assignment[tank.id] = spot
                self.loadout.queue_move(tank)
        elif name in self.gear:
            return "Already fitted."
        else:
            self.gear.add(name)
        self.money -= price
        self.say(f"Fitted: {GEAR[name][1]} (-${price:,})")
        self.fm.apply_loadout(self.loadout)
        return None

    def hire_spotter(self, code: str | None) -> str | None:
        if "spotters" not in self.features:
            return "Nobody to hire yet."
        if code not in AIRFIELD_BY_CODE:
            return "Unknown field."
        if any(s.code == code for s in self.spotters):
            return "Already watching that strip."
        self.money -= SPOTTER_FEE
        self.spotters.append(Spotter(code))
        self.say(f"Spotter watching {AIRFIELD_BY_CODE[code].name} (-${SPOTTER_FEE})")
        return None

    def set_copilot(self, who: str | None) -> None:
        """'human', 'ai' or None. Changes the weight in the right seat."""
        self.copilot = who
        self.loadout.copilot_aboard = bool(who)
        self.fm.apply_loadout(self.loadout)

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
        for j in self.active_jobs:
            if j.boat_id and (b := self.maritime.boat(j.boat_id)):
                b.state = "running"
        self.active_jobs.clear()
        self.loadout = Loadout(self.spec, self.loadout.mass, fuel_lb=self.loadout.mass.fuel_capacity_lb * 0.5,
                               copilot_aboard=bool(self.copilot))
        self.police.reset()
        self.spawn_at(code)

    # ================================================================ in-flight crew work
    def request_kick(self, role: Role, count: int = 1) -> str | None:
        s = self.state
        if s is None or s.on_ground:
            return "Kick them out in the air, not on the ramp."
        if s.ias_kts > KICK_MAX_KTS:
            return f"Too fast to open the door (max {KICK_MAX_KTS:.0f} kt)."
        if not self._droppables():
            return "Nothing to kick."
        if role == Role.PILOT and not self.copilot:
            if not self.autopilot.engaged:
                return "Engage the autopilot [U] before you leave the controls."
            self.kicker = "pilot"
        else:
            self.kicker = "copilot"
        self.kick_queue = min(len(self._droppables()), self.kick_queue + max(1, count))
        return None

    def _droppables(self):
        lo = self.loadout
        return [i for i in lo.items.values() if i.droppable and i.id in lo.assignment and i.id not in lo.pending]

    def _crew_work(self, dt: float, s: FlightState) -> None:
        lo = self.loadout
        # loading on the ground
        if s.on_ground and s.gs_kts < 1.0 and lo.pending:
            if lo.work(dt, self.crew_count()):
                self.fm.apply_loadout(lo)
                if not lo.pending:
                    self.say("Loading complete.")
        # AI co-pilot habits
        if self.copilot == "ai" and not s.on_ground:
            if lo.ferry_tanks() and lo.ferry_fuel_lb() > 0 and self.fm.wing_fuel_room() > 0.3 * lo.mass.fuel_capacity_lb:
                self.pumping = True
            if self.auto_kick and self.kick_queue == 0 and self._droppables():
                for j in self.active_jobs:
                    if j.is_airdrop and math.dist((s.x, s.y), j.drop_point) < 450 and s.ias_kts <= KICK_MAX_KTS:
                        self.request_kick(Role.COPILOT, len(self._droppables()))
                        break
        # kicking
        if self.kick_queue > 0:
            if s.on_ground or s.ias_kts > KICK_MAX_KTS + 5:
                self.kick_queue = 0
                self.say("Door closed: too fast / on the ground.")
            else:
                self.kick_t += dt
                if self.kick_t >= KICK_TIME[self.kicker or "copilot"]:
                    self.kick_t = 0.0
                    self._kick_one(s)
        # ferry pump
        if self.pumping:
            tanks = lo.ferry_tanks()
            if not tanks or lo.ferry_fuel_lb() <= 0.1 or self.fm.wing_fuel_room() < 0.5:
                self.pumping = False
                self.say("Ferry pump OFF (tank dry or wings full).")
            else:
                rate = PUMP_RATE_LB_MIN["copilot" if self.copilot else "pilot"] / 60.0
                t = tanks[0]
                move = min(rate * dt, t.fuel_lb)
                added = self.fm.add_fuel(move)
                t.set_fuel(t.fuel_lb - added)
                self.fm.apply_loadout(lo)

    def _kick_one(self, s: FlightState) -> None:
        items = self._droppables()
        if not items:
            self.kick_queue = 0
            return
        item = max(items, key=lambda i: self.spec.stations[self.loadout.assignment[i.id]].x_in)  # nearest the door
        self.loadout.remove_item(item.id)
        self.fm.apply_loadout(self.loadout)
        vz = s.vs_fpm * 0.00508
        self.maritime.drop_bale(item.job_id, s.x, s.y, s.alt - 1.5, s.vx, s.vy, vz, item.weight_lb)
        self.kick_queue -= 1
        left = len(self._droppables())
        self.bus.emit("bale_kicked", self.time, audience=("runner",), job_id=item.job_id)
        self.say(f"Bale away! ({left} left)")

    def call_boat(self) -> str | None:
        s = self.state
        boats = [b for b in self.maritime.boats if b.kind == "gofast" and b.state not in ("seized", "delivered")]
        if not boats:
            return "No boat is out."
        b = boats[0]
        pos = (s.x, s.y) if s else None
        msg = self.radio.transmit(self.time, "runner", self.squawk, f"{b.id}, come to me", pos)
        if s and self.world.is_water(s.x, s.y):
            b.goal, b.state = (s.x, s.y), "to_rendezvous"
        self.say(f"Called {b.id}." + ("" if s and self.world.is_water(s.x, s.y) else " (Over land: boat holds position.)"))
        df = self.radio.direction_find(msg) if "df" in self.features else None
        if df and df.bearings:
            self.law_say(f"DF: {len(df.bearings)} bearing(s) on a runner transmission")
            if df.fix:
                self.police.sensors.add_fix("runner", df.fix[0], df.fix[1], self.time, "DF")
                self.police.tips.append(Tip(self.time, df.fix[0], df.fix[1], 800, "DF fix"))
                self.police.case("runner").last_known = (df.fix[0], df.fix[1], self.time)
                self.police.case("runner").suspicion = min(100.0, self.police.case("runner").suspicion + 30)
        return None

    # ================================================================ tick
    def update(self, dt: float, inp: InputFrame | None = None) -> None:
        self.time += dt
        inp = inp or InputFrame()
        if self.runner_active:
            self._update_runner(dt, inp)
        self._update_world(dt)
        if self.campaign is not None:
            self.campaign.tick(self)

    def _update_runner(self, dt: float, inp: InputFrame) -> None:
        if self.phase in ("crashed", "busted"):
            if "confirm" in inp.pressed:
                self.respawn()
            return
        pilot_aft = self.kicker == "pilot" and self.kick_queue > 0
        if pilot_aft:
            inp = InputFrame()  # nobody at the controls
        elif self.autopilot.engaged and (inp.held & {"pitch_up", "pitch_down", "roll_left", "roll_right"} or inp.stick):
            self.autopilot.disengage()
            self.say("Autopilot disconnected")
        controls = self.mapper.update(dt, inp)
        if self.state is not None and self.autopilot.engaged:
            controls = self.autopilot.update(dt, self.state, controls)
        if self.parked and not ({"throttle_up", "brake"} & inp.held) and controls.throttle < 0.05:
            controls.brake = 1.0  # parking brake while in menus
        if self.phase == "parked" and self.loadout.busy() and controls.throttle > 0.05:
            controls.throttle = 0.0
            controls.brake = 1.0
            if not self.messages or self.time - self.messages[-1][0] > 4:
                what = "Still loading" if self.loadout.pending else "Cargo still on the ramp! Load it [L] or drop the job [J]"
                self.say(what + ".")
        self.fm.controls = controls
        s = self.fm.step(dt, self.world.ground)
        self.state = s
        if s.valid:
            self.loadout.fuel_lb = s.fuel_lb
        self._rules(dt, s)
        if self.phase not in ("crashed", "busted"):
            self._crew_work(dt, s)

    def runner_signature(self) -> Signature | None:
        s = self.state
        if s is None or not self.runner_active or self.phase != "flying":
            return None
        agl = s.alt - self.world.ground(s.x, s.y) - self.fm.mass.gear_height_ft * FT
        return Signature("runner", s.x, s.y, s.alt, agl, s.vx, s.vy, "air", self.transponder, self.squawk)

    def _update_world(self, dt: float) -> None:
        targets: list[Target] = []
        sig = self.runner_signature()
        if sig is not None:
            targets.append(Target(sig, self.carrying_hot(), self.hot_value(), self.squawk if self.transponder else "runner"))
        # AI runs (police mode)
        if self.mode == Mode.POLICE:
            active = [a for a in self.smugglers if a.active]
            if self.director.due(self.time, len(active)):
                self._spawn_ai_run()
                self.director.schedule_next(self.time)
        law_air = [(u.x, u.y, u.z) for u in self.police.units if u.faction == "police" and u.state != "crashed"]
        for a in self.smugglers:
            if not a.active:
                continue
            tr = a.update(dt, self.world, law_air, lambda jid, x, y, z, vx, vy: self.maritime.drop_bale(jid, x, y, z, vx, vy, 0.0, 60))
            if tr == "escaped":
                self.runner_score["escapes"] += 1
                self.law_say(f"{self.police.alias(a.id)} left the area - escaped")
            elif tr == "crashed":
                self.law_say(f"{self.police.alias(a.id)} crashed")
            if a.active:
                targets.append(Target(a.signature(self.world), True, 5000, a.id))

        outcomes = self.police.tick(dt, self.time, targets)
        for tid, what in outcomes.items():
            if tid == "runner":
                self._police_outcome(what)
            else:
                a = next((a for a in self.smugglers if a.id == tid), None)
                if a:
                    a.state = "busted"
                    self.bus.emit("ai_busted", self.time, audience=("law",), id=tid)
        for e in self.police.events:
            self.say(e)
        self.police.events.clear()
        for e in self.police.law_events:
            self.law_say(e)
        self.police.law_events.clear()

        # maritime: cutters go where the task force suspects a drop
        law_goals = [(t.x, t.y) for t in self.police.tips if self.time - t.t < 600 and t.text in ("possible airdrop", "DF fix")]
        if self.police.controller == "ai" and law_goals and "cutters" in self.features and self.police.stock.get("cutter", 0) > 0:
            self.police.stock["cutter"] -= 1
            c = self.maritime.new_cutter(law_goals[-1])
            self.radio.transmit(self.time, "police", c.id, "underway to suspected drop", (c.x, c.y))
        self.maritime.update(dt, law_goals if self.police.controller == "ai" else [])
        for kind, data in self.maritime.events:
            self._maritime_event(kind, data)
        self.maritime.events.clear()

        self._update_intel(dt)

    def _spawn_ai_run(self) -> None:
        self.director.serial += 1
        rng = self.director.rng
        entry, exit_, hdg = entry_and_exit(rng)
        drop = random_drop_point(self.world, rng, near=self.maritime.cove)
        jid = new_id()
        a = AISmuggler(f"Runner-{self.director.serial}", entry[0], entry[1], 150.0, hdg, drop, exit_, jid,
                       bales_left=rng.randint(4, 7))
        self.smugglers.append(a)
        self.maritime.new_gofast(drop, jid)
        self.law_say("Intel: a run is expected tonight.")

    def _police_outcome(self, what: str) -> None:
        if what == "busted":
            self._bust("forced down by police")
        elif what == "clean":
            fine = 500 if not self.transponder else 0
            self.money -= fine
            self.say("Police forced you down and searched the aircraft: clean." + (f" Fined ${fine} for no transponder." if fine else ""))
        elif what == "hijacked":
            lost = [j for j in self.active_jobs if j.hot]
            for j in lost:
                self.active_jobs.remove(j)
                self.loadout.remove_job(j.id)
            self.fm.apply_loadout(self.loadout)
            self.say("Rivals forced you to jettison the goods!")

    def _maritime_event(self, kind: str, data: dict) -> None:
        job = next((j for j in self.active_jobs if j.id == data.get("job_id")), None)
        if kind == "bales_delivered":
            n = data["count"]
            self.runner_score["bales_delivered"] += n
            if job:
                pay = int(job.payout * n / max(1, job.bales_total))
                self.money += pay
                job.bales_delivered = n
                self._resolve_job(job, f"{data['boat']} made the cove with {n}/{job.bales_total} bales: +${pay:,}")
            self.bus.emit("bales_delivered", self.time, audience=("runner",), count=n, job_id=data.get("job_id"))
        elif kind == "boat_seized":
            self.police.score["boats_seized"] += 1
            self.police.score["bales_seized"] += data["count"]
            self.law_say(f"{data['cutter']} seized {data['boat']} with {data['count']} bales")
            if job:
                self._resolve_job(job, f"Coast Guard took {data['boat']}! Job lost.")
            self.bus.emit("boat_seized", self.time, **data)
        elif kind == "bale_seized":
            self.police.score["bales_seized"] += 1
            self.law_say(f"{data['cutter']} recovered a floating bale")
        elif kind == "bale_splash" and job:
            self.say("Splash - bale in the water.")
        elif kind == "bale_lost" and job:
            self.say(f"Bale lost ({data['why']}).")
        elif kind == "boat_fleeing" and job:
            self.say(f"{data['boat']}: cutter on us, running!")
        elif kind == "cutter_contact":
            self.radio.transmit(self.time, "police", data["cutter"], "surface contact, go-fast, pursuing", (data["x"], data["y"]))

    def _resolve_job(self, job: Job, text: str) -> None:
        job.resolved = True
        if job in self.active_jobs:
            self.active_jobs.remove(job)
        self.say(text)

    def _update_intel(self, dt: float) -> None:
        """Scanner intercepts and spotter reports -> runner-side knowledge of police."""
        if "scanner" in self.gear and "scanner" in self.features:
            for t, text in self.radio.scanner(self._scanner_seen):
                self.scanner_log.append((t, text))
            for m in self.radio.channel("police", self._scanner_seen):
                if not m.encrypted and m.x is not None:
                    self.intel[m.sender] = (m.t, m.x, m.y, "scanner")
            del self.scanner_log[:-30]
        self._scanner_seen = self.time
        for sp in self.spotters:
            if sp.moving_to:
                sp.move_t -= dt
                if sp.move_t <= 0:
                    sp.code, sp.moving_to = sp.moving_to, None
                    self.say(f"Spotter in position at {AIRFIELD_BY_CODE[sp.code].name}.")
                continue
            if self.time - sp.last_report_t < 8.0:
                continue
            sp.last_report_t = self.time
            af = AIRFIELD_BY_CODE[sp.code]
            seen = [u for u in self.police.units if u.faction == "police" and u.state != "crashed"
                    and math.hypot(u.x - af.x, u.y - af.y) < SPOTTER_RANGE_M]
            for u in seen:
                self.intel[u.id] = (self.time + SPOTTER_DELAY_S, u.x, u.y, f"spotter@{sp.code}")
            if seen:
                self.say(f"Spotter@{sp.code}: {len(seen)} police unit(s) near the strip!")
        # forget stale intel
        self.intel = {k: v for k, v in self.intel.items() if self.time - v[0] < 90}

    # ================================================================ rules
    def _crash(self, reason: str) -> None:
        self.phase = "crashed"
        fee = max(2500, int(self.spec.price * 0.12))
        self.money -= fee
        lost = len(self.active_jobs)
        self.last_outcome = f"CRASH: {reason}. Repairs -${fee:,}." + (f" {lost} job(s) lost." if lost else "")
        self.say(self.last_outcome)
        self.bus.emit("crashed", self.time, reason=reason)

    def _bust(self, how: str) -> None:
        self.phase = "busted"
        fine = 1500 + int(max(0, self.money) * 0.25)
        self.money -= fine
        self.last_outcome = f"BUSTED ({how}). Fine and impound -${fine:,}. Cargo seized."
        self.say(self.last_outcome)
        self.police.score["busts"] += 1
        self.law_say(f"BUST: {self.squawk} ({how})")
        self.bus.emit("busted", self.time, how=how)

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
                self.police.reset(keep_wanted=True)
            log.max_bank = max(log.max_bank, abs(s.roll))
        elif self.phase == "parked" and s.gs_kts > 3:
            log.departed_from = log.departed_from or self.location

        # --- collisions
        if self.world.tree_hit(s.x, s.y, s.alt - fm.mass.gear_height_ft * FT, radius=4.0):
            return self._crash("Hit trees")
        if abs(s.x) > HALF + 3000 or abs(s.y) > HALF + 3000:
            if not self.messages or self.time - self.messages[-1][0] > 6:
                self.say("Leaving the operating area - turn back!")

        # --- touchdowns
        if fm.touchdowns != log.touchdowns_seen:
            log.touchdowns_seen = fm.touchdowns
            fpm = -fm.last_touchdown_fpm
            log.last_touchdown_fpm = fpm
            log.max_touchdown_fpm = max(log.max_touchdown_fpm, fpm)
            limit = self.spec.gear_limit_fpm * (0.75 if self.loadout.compute(planned=False).overweight_lb > 0 else 1.0)
            if fpm > limit:
                return self._crash(f"Gear collapsed on a {fpm:.0f} fpm touchdown")
            if log.airborne:
                self.say(f"Touchdown {fpm:.0f} fpm" + (" - butter!" if fpm < 150 else ""))

        if s.on_ground:
            self.autopilot.disengage()
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

    def _arrive(self, af: Airfield, s: FlightState) -> None:
        self.phase = "parked"
        self.location = af.code
        if self.police.landing_check(s, af, self.carrying_hot()):
            return self._bust(f"arrested on landing at {af.name}")
        delivered = [j for j in self.active_jobs if j.dest == af.code]
        for job in delivered:
            drums = [i for i in job.items if i.label == "Fuel drum"]
            if drums and af.kind in ("bush", "shady"):
                fuel = sum(i.weight_lb for i in drums) * 0.9
                self.fuel_caches[af.code] = self.fuel_caches.get(af.code, 0.0) + fuel
                self.say(f"{fuel:.0f} lb of fuel cached at {af.name}.")
            pay, notes = self._grade(job)
            self.money += pay
            self.active_jobs.remove(job)
            self.loadout.remove_job(job.id)
            self.say(f"Delivered '{job.title}': +${pay:,} {notes}".rstrip())
            self.bus.emit("job_delivered", self.time, audience=("runner",), job_id=job.id, pay=pay, dest=af.code,
                          hot=job.hot)
        self.fm.apply_loadout(self.loadout)
        self.police.reset(keep_wanted=True)
        self.log = FlightLog()
        self.refresh_board(af.code)
        if not delivered:
            self.say(f"Parked at {af.name}.")
        self.bus.emit("landed", self.time, audience=("runner",), code=af.code)
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
            "gear": sorted(self.gear),
        }
        if self.campaign is not None:
            data["campaign"] = self.campaign.to_dict()
        self.save_path.write_text(json.dumps(data, indent=2))

    @staticmethod
    def read_save(save_path: Path) -> dict:
        if save_path.exists():
            try:
                return json.loads(save_path.read_text())
            except (OSError, ValueError):
                return {}
        return {}

    @classmethod
    def load_or_new(cls, save_path: Path, **kw) -> "Session":
        data = cls.read_save(save_path)
        sess = cls(
            money=data.get("money", START_MONEY),
            owned=set(data.get("owned", ["c172p"])) & set(ROSTER) or {"c172p"},
            aircraft_key=data.get("aircraft", "c172p") if data.get("aircraft") in ROSTER else "c172p",
            location=data.get("location", START_FIELD) if data.get("location") in AIRFIELD_BY_CODE else START_FIELD,
            gear=set(data.get("gear", [])) & set(GEAR),
            save_path=save_path,
            **kw,
        )
        return sess


__all__ = ["Session", "FlightLog", "MODE_ROLES", "GEAR", "RUNNER_FEATURES", "SANDBOX_FEATURES"]
