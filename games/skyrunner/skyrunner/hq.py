"""The strategic layer: the Organisation vs the Task Force over a season.

A season is a run of nights. Each night has three phases:

  planning   both HQs spend money and a few action points, in secret
  operation  the runs happen - flown by people in the 3D game, by bots, or
             resolved by `resolve_abstract` in the fast balance simulator
  debrief    results feed back: dirty money, seizures, evidence, heat, budget

The same rules object runs the live game and the balance simulator, so what
the simulator learns applies to what people play.

Design notes (see docs/MULTIPLAYER.md for the reasoning):

* Asymmetric goals, one race. The Organisation wins by laundering enough
  clean money to retire; the Task Force wins by building a case (evidence)
  big enough to indict the boss. Both clocks run every night, so neither side
  can turtle.
* Every tool has a counter. Wiretap <- burner phones; informants <- loyalty
  bonuses and a counter-intelligence sweep; audits <- spreading money over
  more fronts; bribes <- internal-affairs sweeps; decoys <- nothing but
  patience (they cost money every night).
* Negative feedback on runaway success. Heat raises public pressure, which
  raises the Task Force budget; seizures fund the police (1984-style
  equitable sharing) but support decays; a side that falls far behind gets a
  historical comeback event (the federal task force arrives / the cartel pays
  more for pilots who'll still fly).
* Hidden information. Each HQ sees its own books exactly and the other side
  only through rumours, news and whatever its sources (bribes, informants,
  wiretaps) give it.
"""
from __future__ import annotations

import math
import random
from dataclasses import asdict, dataclass, field

# ----------------------------------------------------------------- tunables
# Every number the balance simulator is allowed to move lives here.
RULES: dict[str, float] = {
    "nights": 10,
    "retire_target": 60_000,  # clean $ to win
    "indict_evidence": 100.0,
    "start_dirty": 12_000,
    "start_budget_k": 20.0,
    "actions_per_night": 3,
    "overhead": 1_500,  # per night: crew wages, hangar, "consulting"
    "run_payout": 13_000,  # base value of one run for the C172
    "crew_fee": 3_000,  # contract crew (AI run)
    "crew_share": 0.6,  # organisation's share of a contract crew's load
    "decoy_fee": 1_500,
    "heat_decay": 6.0,
    "lie_low_decay": 18.0,
    "support_base_k": 12.0,  # law budget = base + support term + heat term
    "support_k": 12.0,
    "heat_k": 0.10,
    "seizure_share": 0.8,  # fraction of seized value paid to the task force (1984: up to 80%)
    "evidence_bust": 12.0,
    "evidence_flip": 10.0,
    "evidence_informant": 2.5,  # per informant per night
    "evidence_wiretap": 4.0,
    "evidence_audit_k": 6.0,  # per point of laundering exposure
    "evidence_bribe": 12.0,
    "evidence_decay": 1.5,
    "flip_base": 0.55,
    "tip_base": 0.30,  # chance an informant hears about tonight's route
    "comeback_gap": 0.25,
    "fed_bonus_k": 10.0,
    "cartel_bonus": 0.30,
}

ZONES = ("west", "north", "sea")
ZONE_CENTRE = {"west": (-9000.0, 3000.0), "north": (2000.0, 8000.0), "sea": (13000.0, -11000.0)}
ZONE_FIELDS = {"west": ("QRY", "FRM"), "north": ("EGL", "PNR", "ISL"), "sea": ("COV",)}
ZONE_PAY = {"west": 1.0, "north": 1.15, "sea": 1.3}

AIRCRAFT_TIERS = (  # (key, price, payout multiplier, heat on purchase)
    ("c172p", 0, 1.0, 0),
    ("c182", 25_000, 1.4, 6),
    ("c310", 70_000, 2.2, 12),
)

FRONTS = {  # name: (price, laundering capacity per night, fee)
    "laundromat": (6_000, 4_000, 0.10),
    "car_lot": (18_000, 9_000, 0.15),
    "marina": (40_000, 20_000, 0.20),
}

BRIBES = {  # name: (cost per night, what it does)
    "harbor": (2_000, "harbor master: cutters sail late, one fewer at sea"),
    "tower": (1_500, "tower chief: no customs checks at police fields"),
    "dispatcher": (3_000, "police dispatcher: you hear the patrol plan and every radio call"),
}

LAW_COSTS_K = {  # $k per night unless noted
    "heli": 3.0, "interceptor": 5.0, "cutter": 4.0, "aerostat": 4.0,
    "informant": 3.0, "informant_upkeep": 1.0, "wiretap": 7.0, "audit": 4.0,
    "ia_sweep": 4.0, "encryption": 5.0,  # one-off
}

RUNNER_ACTIONS = ("launder", "buy_front", "bribe", "drop_bribe", "loyalty", "lawyer", "opsec",
                  "counterintel", "crews", "decoys", "route", "lie_low", "upgrade", "gear", "ready")
GEAR_PRICES = {"scanner": 1_800, "detector": 2_500}
LAW_ACTIONS = ("fund", "patrol", "aerostat", "recruit", "wiretap", "audit", "ia_sweep",
               "encryption", "press", "ready")
FREE_ACTIONS = {"launder", "route", "ready", "drop_bribe"}  # don't cost an action point


@dataclass
class Org:
    dirty: int = 0
    clean: int = 0
    heat: float = 10.0
    loyalty: float = 0.5
    fronts: list[str] = field(default_factory=lambda: ["laundromat"])
    bribes: set[str] = field(default_factory=set)
    lawyer: bool = False
    tier: int = 0  # index into AIRCRAFT_TIERS
    exposure: float = 0.0  # laundering that looks wrong on paper
    gear: set[str] = field(default_factory=set)  # scanner, detector (tactical)
    # tonight
    opsec: bool = False
    crews: int = 0
    decoys: int = 0
    route: str = "west"
    lie_low: bool = False
    counterintel: bool = False
    laundered_tonight: int = 0
    actions: int = 0
    ready: bool = False

    @property
    def capacity(self) -> int:
        return sum(FRONTS[f][1] for f in self.fronts)

    @property
    def payout_mult(self) -> float:
        return AIRCRAFT_TIERS[self.tier][2]


@dataclass
class TaskForce:
    bank_k: float = 0.0
    support: float = 50.0
    evidence: float = 0.0
    informants: int = 0
    encryption: bool = False
    fed_arrived: bool = False
    # tonight
    budget_k: float = 0.0
    funded: dict[str, int] = field(default_factory=lambda: {"heli": 0, "interceptor": 0, "cutter": 0})
    aerostat: bool = False
    patrol: str | None = None
    wiretap: bool = False
    audit: bool = False
    ia_sweep: bool = False
    press: bool = False
    actions: int = 0
    ready: bool = False


@dataclass
class RunResult:
    """One flight's outcome, from the 3D game, a bot or the abstract resolver."""
    kind: str  # main | crew | decoy
    zone: str
    detected: bool = False
    intercepted: bool = False
    busted: bool = False
    crashed: bool = False
    boat_seized: bool = False
    delivered_value: int = 0  # dirty $ to the organisation
    seized_value: int = 0  # street value taken by the police
    clean_stop: bool = False  # police forced down a clean aircraft (decoy)


@dataclass
class NightReport:
    night: int
    runs: list[RunResult]
    lines: list[str] = field(default_factory=list)  # public news
    runner_lines: list[str] = field(default_factory=list)
    law_lines: list[str] = field(default_factory=list)


class Season:
    def __init__(self, rng: random.Random | None = None, rules: dict | None = None):
        self.rng = rng or random.Random()
        self.rules = dict(RULES, **(rules or {}))
        R = self.rules
        self.org = Org(dirty=int(R["start_dirty"]))
        self.law = TaskForce(bank_k=0.0)
        self.night = 1
        self.phase = "planning"  # planning | operation | debrief | over
        self.winner: str | None = None
        self.reason: str = ""
        self.history: list[dict] = []
        self.reports: list[NightReport] = []
        self.runner_log: list[str] = []
        self.law_log: list[str] = []
        self.cartel_bonus = False
        self.plan: dict = {}
        self.plan_hist: list[dict] = []
        self._begin_planning()

    # ============================================================ planning
    def _begin_planning(self) -> None:
        o, L, R = self.org, self.law, self.rules
        self.phase = "planning"
        o.opsec = o.lie_low = o.counterintel = False
        o.crews = o.decoys = 0
        o.laundered_tonight = 0
        o.actions = int(R["actions_per_night"])
        o.ready = False
        L.funded = {"heli": 0, "interceptor": 0, "cutter": 0}
        L.aerostat = L.wiretap = L.audit = L.ia_sweep = L.press = False
        L.patrol = None
        L.actions = int(R["actions_per_night"])
        L.ready = False
        L.budget_k = (R["support_base_k"] + R["support_k"] * L.support / 100.0 + R["heat_k"] * o.heat
                      + L.bank_k - LAW_COSTS_K["informant_upkeep"] * L.informants)
        if self.night == 1:
            L.budget_k += R["start_budget_k"] - R["support_base_k"]
        L.bank_k = 0.0
        # standing costs come off the organisation's books up front
        standing = R["overhead"] + sum(BRIBES[b][0] for b in o.bribes) + (3_000 if o.lawyer else 0)
        o.dirty -= int(standing)

    def runner_cmd(self, name: str, /, **a) -> str | None:
        """Returns an error string, or None if done."""
        if self.phase != "planning":
            return "HQ decisions happen between runs."
        if name not in RUNNER_ACTIONS:
            return f"Unknown order {name}."
        o = self.org
        if name not in FREE_ACTIONS and o.actions <= 0:
            return "No more moves tonight."
        err = getattr(self, f"_r_{name}")(**a)
        if err is None and name not in FREE_ACTIONS:
            o.actions -= 1
        return err

    def law_cmd(self, name: str, /, **a) -> str | None:
        if self.phase != "planning":
            return "Plans are set between operations."
        if name not in LAW_ACTIONS:
            return f"Unknown order {name}."
        L = self.law
        if name not in ("ready", "fund", "patrol") and L.actions <= 0:
            return "No more moves tonight."
        err = getattr(self, f"_l_{name}")(**a)
        if err is None and name not in ("ready", "fund", "patrol"):
            L.actions -= 1
        return err

    # ---- organisation orders
    def _r_launder(self, amount: int | None = None) -> str | None:
        o = self.org
        room = o.capacity - o.laundered_tonight
        amount = room if amount is None else min(int(amount), room)
        amount = min(amount, max(0, o.dirty))
        if amount <= 0:
            return "Nothing to wash (or the fronts are full tonight)."
        fee = sum(FRONTS[f][2] * FRONTS[f][1] for f in o.fronts) / max(1, o.capacity)
        o.dirty -= amount
        o.clean += int(amount * (1 - fee))
        o.laundered_tonight += amount
        return None

    def _r_buy_front(self, kind: str) -> str | None:
        o = self.org
        if kind not in FRONTS:
            return "Unknown front."
        price = FRONTS[kind][0]
        if o.dirty < price:
            return f"Need ${price:,} in cash."
        o.dirty -= price
        o.fronts.append(kind)
        o.heat += 3
        self.runner_log.append(f"Bought a {kind.replace('_', ' ')} (+${FRONTS[kind][1]:,}/night laundering)")
        return None

    def _r_bribe(self, who: str) -> str | None:
        o = self.org
        if who not in BRIBES or who in o.bribes:
            return "Can't bribe that."
        if o.dirty < BRIBES[who][0]:
            return "Not enough cash."
        o.bribes.add(who)
        o.dirty -= BRIBES[who][0]  # first night paid now; then standing cost
        self.runner_log.append(f"On the payroll: {BRIBES[who][1]}")
        return None

    def _r_drop_bribe(self, who: str) -> str | None:
        self.org.bribes.discard(who)
        return None

    def _r_loyalty(self) -> str | None:
        o = self.org
        if o.dirty < 2_500:
            return "Not enough cash."
        o.dirty -= 2_500
        o.loyalty = min(1.0, o.loyalty + 0.2)
        return None

    def _r_lawyer(self, on: bool = True) -> str | None:
        self.org.lawyer = bool(on)
        return None

    def _r_opsec(self) -> str | None:
        o = self.org
        if o.dirty < 1_000:
            return "Not enough cash."
        o.dirty -= 1_000
        o.opsec = True
        return None

    def _r_counterintel(self) -> str | None:
        o = self.org
        if o.dirty < 5_000:
            return "Not enough cash."
        o.dirty -= 5_000
        o.counterintel = True
        return None

    def _r_crews(self, n: int = 1) -> str | None:
        o, R = self.org, self.rules
        n = max(0, min(2, int(n)))
        cost = int(R["crew_fee"]) * n
        if o.dirty < cost:
            return "Not enough cash."
        o.dirty -= cost
        o.crews = n
        return None

    def _r_decoys(self, n: int = 1) -> str | None:
        o, R = self.org, self.rules
        n = max(0, min(2, int(n)))
        cost = int(R["decoy_fee"]) * n
        if o.dirty < cost:
            return "Not enough cash."
        o.dirty -= cost
        o.decoys = n
        return None

    def _r_route(self, zone: str) -> str | None:
        if zone not in ZONES:
            return "Unknown zone."
        self.org.route = zone
        return None

    def _r_lie_low(self) -> str | None:
        self.org.lie_low = True
        return None

    def _r_upgrade(self) -> str | None:
        o = self.org
        if o.tier + 1 >= len(AIRCRAFT_TIERS):
            return "Already flying the best."
        _, price, _, heat = AIRCRAFT_TIERS[o.tier + 1]
        if o.dirty < price:
            return f"Need ${price:,}."
        o.dirty -= price
        o.tier += 1
        o.heat += heat
        self.runner_log.append(f"New aircraft: {AIRCRAFT_TIERS[o.tier][0]}")
        return None

    def _r_gear(self, name: str) -> str | None:
        o = self.org
        if name not in GEAR_PRICES or name in o.gear:
            return "Can't buy that."
        if o.dirty < GEAR_PRICES[name]:
            return "Not enough cash."
        o.dirty -= GEAR_PRICES[name]
        o.gear.add(name)
        return None

    def _r_ready(self) -> str | None:
        self.org.ready = True
        return None

    # ---- task force orders
    def _spend(self, k: float) -> str | None:
        if self.law.budget_k + 1e-9 < k:
            return f"Over budget (${self.law.budget_k:.0f}k left)."
        self.law.budget_k -= k
        return None

    def _l_fund(self, unit: str, n: int = 1) -> str | None:
        if unit not in self.law.funded:
            return "Unknown unit."
        n = max(0, min(3, int(n)))
        diff = n - self.law.funded[unit]
        err = self._spend(diff * LAW_COSTS_K[unit]) if diff > 0 else None
        if err:
            return err
        if diff < 0:
            self.law.budget_k += -diff * LAW_COSTS_K[unit]
        self.law.funded[unit] = n
        return None

    def _l_patrol(self, zone: str | None) -> str | None:
        if zone is not None and zone not in ZONES:
            return "Unknown zone."
        self.law.patrol = zone
        return None

    def _l_aerostat(self) -> str | None:
        err = self._spend(LAW_COSTS_K["aerostat"])
        if not err:
            self.law.aerostat = True
        return err

    def _l_recruit(self) -> str | None:
        if self.law.informants >= 3:
            return "Enough informants to handle."
        err = self._spend(LAW_COSTS_K["informant"])
        if not err:
            # recruiting works better when the crews are unhappy
            if self.rng.random() < 0.85 - 0.5 * self.org.loyalty:
                self.law.informants += 1
                self.law_log.append("New informant inside the organisation.")
            else:
                self.law_log.append("Approach failed - they wouldn't talk.")
        return err

    def _l_wiretap(self) -> str | None:
        if self.law.evidence < 20:
            return "No judge will sign a warrant yet (need 20 evidence)."
        err = self._spend(LAW_COSTS_K["wiretap"])
        if not err:
            self.law.wiretap = True
        return err

    def _l_audit(self) -> str | None:
        err = self._spend(LAW_COSTS_K["audit"])
        if not err:
            self.law.audit = True
        return err

    def _l_ia_sweep(self) -> str | None:
        err = self._spend(LAW_COSTS_K["ia_sweep"])
        if not err:
            self.law.ia_sweep = True
        return err

    def _l_encryption(self) -> str | None:
        if self.law.encryption:
            return "Already encrypted."
        err = self._spend(LAW_COSTS_K["encryption"])
        if not err:
            self.law.encryption = True
        return err

    def _l_press(self) -> str | None:
        busts = sum(1 for r in (self.reports[-1].runs if self.reports else []) if r.busted or r.boat_seized)
        if not busts:
            return "Nothing to show the cameras."
        self.law.press = True
        return None

    def _l_ready(self) -> str | None:
        self.law.ready = True
        return None

    # ============================================================ operation
    def start_operation(self) -> dict:
        """Lock the plans; returns what the tactical layer needs to set up the night."""
        o, L = self.org, self.law
        self.phase = "operation"
        tip = self.informant_tip()
        wire = L.wiretap and not o.opsec
        leak_patrol = "dispatcher" in o.bribes
        plan = {
            "night": self.night,
            "route": o.route,
            "runs": 0 if o.lie_low else 1,
            "crews": 0 if o.lie_low else o.crews,
            "decoys": o.decoys,
            "tier": o.tier,
            "funded": dict(L.funded),
            "cutters": max(0, L.funded["cutter"] - (1 if "harbor" in o.bribes else 0)),
            "aerostat": L.aerostat,
            "patrol": L.patrol,
            "encryption": L.encryption and "dispatcher" not in o.bribes,
            "tip": tip or wire,
            "tip_zone": o.route if (tip or wire) else None,
            "leak_patrol": L.patrol if leak_patrol else None,
            "no_customs": "tower" in o.bribes,
            "informant_mult": 1.0 + L.informants * (1.0 - o.loyalty),
        }
        self.plan = plan
        self.plan_hist.append(plan)
        return plan

    def informant_tip(self) -> bool:
        L, o = self.law, self.org
        if L.informants <= 0 or o.lie_low:
            return False
        p = 1 - (1 - self.rules["tip_base"] * (1.0 - 0.6 * o.loyalty)) ** L.informants
        return self.rng.random() < p

    # ============================================================ debrief
    def finish_night(self, runs: list[RunResult], live: bool = False) -> NightReport:
        """live=True: the main run was flown in the Session, which already paid
        the pilot, charged the fines and the repairs."""
        o, L, R = self.org, self.law, self.rules
        rep = NightReport(self.night, runs)
        # --- the organisation's takings
        for r in runs:
            if r.delivered_value and not (live and r.kind == "main"):
                share = R["crew_share"] if r.kind == "crew" else 1.0
                o.dirty += int(r.delivered_value * share * (1 + (R["cartel_bonus"] if self.cartel_bonus else 0.0)))
            if r.detected and r.kind != "decoy":
                o.heat += 4
            if r.delivered_value:
                o.heat += 2
            if r.crashed and r.kind == "main" and not live:
                o.dirty -= 3_000
                rep.lines.append("Wreck found in the hills. No pilot at the scene.")
            if r.clean_stop:
                L.support -= 4
                rep.lines.append("Police force down a private plane - nothing aboard. Complaints filed.")
            if r.busted:
                o.heat += 10
                L.support += 7
                L.bank_k += r.seized_value / 1000 * R["seizure_share"]
                ev = R["evidence_bust"] * (0.5 if o.lawyer else 1.0)
                L.evidence += ev
                rep.lines.append(f"Pilot arrested with ${r.seized_value:,} of contraband.")
                if r.kind == "main" and not live:
                    o.dirty -= 5_000
                flip = R["flip_base"] * (1 - o.loyalty) * (0.35 if o.lawyer else 1.0)
                if self.rng.random() < flip:
                    L.informants = min(3, L.informants + 1)
                    L.evidence += R["evidence_flip"]
                    rep.law_lines.append("The arrested pilot is talking.")
            if r.boat_seized:
                L.support += 3
                L.evidence += 5
                L.bank_k += r.seized_value / 1000 * R["seizure_share"]
                rep.lines.append("Coast Guard seizes a go-fast boat.")
        # --- investigations
        if L.informants:
            L.evidence += R["evidence_informant"] * L.informants * (1.0 - 0.5 * o.loyalty)
        if L.wiretap:
            if o.opsec:
                rep.law_lines.append("Wiretap: nothing but pay-phone silence.")
            else:
                L.evidence += R["evidence_wiretap"]
                rep.law_lines.append("Wiretap: names, dates, routes.")
        o.exposure += o.laundered_tonight / max(1.0, o.capacity) * (1.0 if o.laundered_tonight > 0.6 * o.capacity else 0.4)
        if L.audit:
            gain = R["evidence_audit_k"] * o.exposure
            L.evidence += gain
            o.exposure = 0.0
            rep.law_lines.append(f"Audit of the fronts: +{gain:.0f} evidence.")
            rep.runner_lines.append("IRS agents went through the books at the fronts.")
        found = []
        for b in sorted(o.bribes):
            p = 0.5 if L.ia_sweep else 0.03
            if self.rng.random() < p:
                found.append(b)
        for b in found:
            o.bribes.discard(b)
            L.evidence += R["evidence_bribe"]
            L.support += 2
            rep.lines.append(f"Corrupt {b} official arrested.")
        if o.counterintel and L.informants:
            burned = sum(1 for _ in range(L.informants) if self.rng.random() < 0.6)
            L.informants -= burned
            if burned:
                rep.runner_lines.append(f"Counter-intel found {burned} rat(s). Handled.")
                rep.law_lines.append(f"{burned} informant(s) went silent.")
        if L.press:
            L.support += 6
            rep.lines.append("Task force parades seized cocaine for the cameras.")
        # --- drift
        o.heat = max(0.0, o.heat - R["heat_decay"] - (R["lie_low_decay"] if o.lie_low else 0.0))
        o.loyalty = max(0.0, o.loyalty - 0.05)
        L.evidence = max(0.0, L.evidence - R["evidence_decay"] - (1.5 if o.lawyer else 0.0))
        L.support += (50.0 - L.support) * 0.1 + o.heat * 0.05
        L.support = max(0.0, min(100.0, L.support))
        L.bank_k += max(0.0, L.budget_k) * 0.5  # half of unspent money rolls over
        o.heat = min(100.0, o.heat)
        self.reports.append(rep)
        self.history.append(self.snapshot_numbers())
        self.phase = "debrief"
        self._check_end()
        return rep

    def snapshot_numbers(self) -> dict:
        o, L = self.org, self.law
        return {"night": self.night, "dirty": o.dirty, "clean": o.clean, "heat": round(o.heat, 1),
                "evidence": round(L.evidence, 1), "support": round(L.support, 1),
                "runner_progress": round(self.runner_progress, 3), "law_progress": round(self.law_progress, 3)}

    @property
    def runner_progress(self) -> float:
        return self.org.clean / self.rules["retire_target"]

    @property
    def law_progress(self) -> float:
        return self.law.evidence / self.rules["indict_evidence"]

    def _check_end(self) -> None:
        o, L, R = self.org, self.law, self.rules
        if o.clean >= R["retire_target"]:
            return self._end("runner", "retired rich")
        if L.evidence >= R["indict_evidence"]:
            return self._end("law", "boss indicted")
        if o.dirty + o.clean < -5_000:
            return self._end("law", "organisation broke")
        if self.night >= R["nights"]:
            rp, lp = self.runner_progress, self.law_progress
            return self._end("runner" if rp >= lp else "law", "season over: " + ("walked free" if rp >= lp else "convicted at trial"))
        # comeback events (once each)
        gap = self.runner_progress - self.law_progress
        if not L.fed_arrived and self.night >= 3 and gap > R["comeback_gap"]:
            L.fed_arrived = True
            L.bank_k += R["fed_bonus_k"]
            L.support = min(100.0, L.support + 10)
            self.reports[-1].lines.append("Washington sends a federal task force to the island.")
        if not self.cartel_bonus and self.night >= 3 and -gap > R["comeback_gap"]:
            self.cartel_bonus = True
            self.reports[-1].lines.append("The cartel raises its price for pilots who'll still fly.")

    def _end(self, who: str, why: str) -> None:
        self.phase = "over"
        self.winner, self.reason = who, why

    def next_night(self) -> None:
        if self.phase == "over":
            return
        self.night += 1
        self._begin_planning()

    # ============================================================ views
    def view(self, side: str) -> dict:
        """What one HQ is allowed to see."""
        o, L = self.org, self.law
        news = self.reports[-1].lines if self.reports else []
        base = {"night": self.night, "nights": int(self.rules["nights"]), "phase": self.phase,
                "winner": self.winner, "reason": self.reason, "news": list(news),
                "public": {"heat": round(o.heat), "support": round(L.support)}}
        if side == "runner":
            rumor = L.evidence if ("dispatcher" in o.bribes or o.lawyer) else None
            band = ("thin", "building", "serious", "closing in")[min(3, int(L.evidence / 25))]
            base.update({
                "org": {k: v for k, v in asdict(o).items() if k not in ("exposure",)},
                "capacity": o.capacity, "retire_target": int(self.rules["retire_target"]),
                "evidence": round(rumor, 1) if rumor is not None else None, "evidence_rumor": band,
                "patrol_leak": L.patrol if "dispatcher" in o.bribes else None,
                "log": self.runner_log[-8:] + (self.reports[-1].runner_lines if self.reports else []),
            })
            base["org"]["bribes"] = sorted(o.bribes)
            base["org"]["gear"] = sorted(o.gear)
        else:
            est = o.clean * self.rng.uniform(0.7, 1.3) if L.audit or L.wiretap else None
            base.update({
                "law": asdict(L), "indict_evidence": self.rules["indict_evidence"],
                "clean_estimate": int(est) if est else None,
                "known_fronts": len(o.fronts), "wiretap_ok": L.evidence >= 20,
                "log": self.law_log[-8:] + (self.reports[-1].law_lines if self.reports else []),
            })
        return base


# ================================================================ abstract night
@dataclass
class Calibration:
    """Per-zone probabilities for the abstract resolver. Defaults are hand
    estimates; `skyrunner.sim.tactical` measures them with bot flights."""
    detect: dict = field(default_factory=lambda: {"west": 0.30, "north": 0.22, "sea": 0.40})
    aerostat_detect: dict = field(default_factory=lambda: {"west": 0.25, "north": 0.20, "sea": 0.35})
    intercept_per_unit: dict = field(default_factory=lambda: {"heli": 0.30, "interceptor": 0.45})
    bust_given_intercept: float = 0.6
    crash: dict = field(default_factory=lambda: {"west": 0.05, "north": 0.06, "sea": 0.02})
    cutter_seize: float = 0.35
    boat_catch_if_spotted: float = 0.5


def resolve_abstract(season: Season, plan: dict, rng: random.Random, cal: Calibration | None = None) -> list[RunResult]:
    """Roll the night's runs without flying them."""
    cal = cal or Calibration()
    o = season.org
    R = season.rules
    runs: list[RunResult] = []
    kinds = ["main"] * plan["runs"] + ["crew"] * plan["crews"] + ["decoy"] * plan["decoys"]
    n_tracks = len(kinds)
    units = plan["funded"]
    for i, kind in enumerate(kinds):
        zone = plan["route"] if kind == "main" else rng.choice(ZONES)
        r = RunResult(kind, zone)
        p_det = cal.detect[zone] + (cal.aerostat_detect[zone] if plan["aerostat"] else 0.0)
        if kind == "main" and plan["tip"]:
            p_det += 0.45
        if kind == "decoy":
            p_det += 0.25  # decoys want to be seen
        p_det = min(0.97, p_det)
        r.detected = rng.random() < p_det
        if r.detected:
            match = 1.6 if plan["patrol"] == zone else (1.2 if kind == "main" and plan["tip"] else 0.8)
            if kind == "main" and plan["leak_patrol"] == zone:
                match *= 0.5  # they knew where the patrol was and went round it
            haz = (units["heli"] * cal.intercept_per_unit["heli"] + units["interceptor"] * cal.intercept_per_unit["interceptor"])
            haz *= match
            haz /= 1.0 + 0.6 * max(0, n_tracks - 1) / max(1, units["heli"] + units["interceptor"])  # spread thin
            if "scanner" in o.gear and not plan["encryption"]:
                haz *= 0.75
            if "detector" in o.gear:
                haz *= 0.85
            r.intercepted = rng.random() < 1 - math.exp(-haz)
            if r.intercepted:
                speed_edge = 0.12 * o.tier if kind == "main" else 0.0
                if rng.random() < cal.bust_given_intercept - speed_edge:
                    if kind == "decoy":
                        r.clean_stop = True
                    else:
                        r.busted = True
        if kind != "decoy" and not r.busted:
            r.crashed = rng.random() < cal.crash[zone] * (1.0 if kind == "main" else 0.7)
        value = int(R["run_payout"] * ZONE_PAY[zone] * (o.payout_mult if kind == "main" else 1.0))
        if r.busted:
            r.seized_value = value * 3  # street value
        elif kind != "decoy" and not r.crashed:
            if zone == "sea" and plan["cutters"]:
                p = cal.cutter_seize * plan["cutters"] * (1.6 if r.detected else 0.7)
                if rng.random() < min(0.9, p):
                    r.boat_seized = True
                    r.seized_value = value * 3
            if not r.boat_seized:
                r.delivered_value = value
        runs.append(r)
    return runs
