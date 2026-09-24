"""Rule layers and seat plans: more players, more layers.

Research on asymmetric multiplayer design (see docs/MULTIPLAYER.md) says every
seat needs meaningful decisions every minute and every tool needs a counter.
So rather than one rule set for everyone, the game stacks layers and turns on
as many as the table can keep busy:

  L1 Flight        weight & balance, fuel, strips, legal jobs
  L2 Heat          contraband, radar, suspicion, police aircraft
  L3 Crew          co-pilot, timed loading, airdrops, go-fast boats, cutters, ferry tanks
  L4 Intel         scanner vs encryption, detector vs aerostat, spotters, DF, informants
  L5 Organisation  a season of nights: HQs, laundering, bribes, evidence, budgets

`plan_match(players)` picks the layer and deals out seats so the two sides
stay balanced even when their head-counts differ: the AI fills the empty
seats, and each extra human unlocks the layer that gives them a job.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .roles import Mode, Role


@dataclass(frozen=True)
class Layer:
    level: int
    name: str
    summary: str
    features: frozenset[str]


LAYERS: tuple[Layer, ...] = (
    Layer(1, "Flight", "Weight & balance, fuel, short strips, legal jobs", frozenset()),
    Layer(2, "Heat", "Contraband, radar, suspicion and police aircraft",
          frozenset({"contraband", "interceptors", "rivals"})),
    Layer(3, "Crew", "Co-pilot, timed loading, airdrops to go-fast boats, cutters, ferry tanks",
          frozenset({"copilot", "airdrop", "ferry", "cutters"})),
    Layer(4, "Intel", "Scanners vs encryption, detectors vs the aerostat, spotters, radio DF, informants",
          frozenset({"scanner", "detector", "spotters", "df", "encryption", "aerostat", "informants"})),
    Layer(5, "Organisation", "A season of nights between two HQs: laundering, bribes, evidence, budgets",
          frozenset({"hq"})),
)


def features_for(level: int) -> set[str]:
    out: set[str] = set()
    for layer in LAYERS[:max(1, min(level, len(LAYERS)))]:
        out |= layer.features
    return out


@dataclass
class Seat:
    role: Role
    human: bool

    def __str__(self) -> str:
        return f"{self.role.value}{'' if self.human else ' (AI)'}"


@dataclass
class MatchPlan:
    players: int
    mode: Mode
    layer: int
    seats: list[Seat] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def features(self) -> set[str]:
        return features_for(self.layer)

    def humans(self, side: str) -> list[Role]:
        return [s.role for s in self.seats if s.human and s.role.side.value == side]

    def describe(self) -> str:
        lay = LAYERS[self.layer - 1]
        run = ", ".join(str(s) for s in self.seats if s.role.side.value == "runner")
        law = ", ".join(str(s) for s in self.seats if s.role.side.value == "law")
        return (f"{self.players} player(s), {self.mode.value}, layer {self.layer} ({lay.name})\n"
                f"  runners: {run}\n  law:     {law}" + "".join(f"\n  - {n}" for n in self.notes))


# the order humans are seated in; AI covers the rest
VERSUS_ORDER = (Role.PILOT, Role.CONTROLLER, Role.COPILOT, Role.INTERCEPTOR,
                Role.BOSS, Role.CHIEF, Role.SPOTTER, Role.CUTTER, Role.BOAT)
COOP_ORDER = (Role.PILOT, Role.COPILOT, Role.SPOTTER, Role.BOSS, Role.BOAT)
VERSUS_LAYER = {1: 3, 2: 4, 3: 4, 4: 4, 5: 5}  # players -> layer (6+ -> 5)
COOP_LAYER = {1: 3, 2: 3, 3: 4, 4: 5}


def plan_match(players: int, versus: bool = True, layer: int | None = None) -> MatchPlan:
    players = max(1, int(players))
    if players == 1 or not versus:
        order, mode = COOP_ORDER, (Mode.SOLO if players == 1 else Mode.COOP)
        lvl = layer or COOP_LAYER.get(players, 5)
    else:
        order, mode = VERSUS_ORDER, Mode.VERSUS
        lvl = layer or VERSUS_LAYER.get(players, 5)
    humans = list(order[:players])
    plan = MatchPlan(players, mode, lvl)
    # seats that exist at this layer
    wanted = [Role.PILOT, Role.CONTROLLER]
    if lvl >= 3:
        wanted += [Role.COPILOT, Role.INTERCEPTOR, Role.BOAT, Role.CUTTER]
    if lvl >= 4:
        wanted += [Role.SPOTTER]
    if lvl >= 5:
        wanted += [Role.BOSS, Role.CHIEF]
    for r in humans:
        if r not in wanted:
            wanted.append(r)
    for r in wanted:
        plan.seats.append(Seat(r, r in humans))
    run_h, law_h = len(plan.humans("runner")), len(plan.humans("law"))
    if mode == Mode.VERSUS and run_h != law_h:
        plan.notes.append(f"{'Runners' if run_h > law_h else 'Law'} have the extra human; "
                          "the other side's AI seats play at full strength.")
    if lvl >= 5 and Role.BOSS not in humans:
        plan.notes.append("No human boss: the pilot gets the HQ screen between nights (or the AI runs it).")
    if lvl >= 5 and mode == Mode.VERSUS and Role.CHIEF not in humans:
        plan.notes.append("No human chief: the controller gets the budget screen between nights (or the AI runs it).")
    return plan
