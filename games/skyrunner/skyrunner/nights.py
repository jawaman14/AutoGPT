"""Nights: the bridge between the HQ season (hq.Season) and the live Session.

  planning   the runner crew is on the ground; both HQs give orders (humans
             through the station, or HQ bots). The pilot loads up meanwhile.
  operation  starts when the pilot takes off with something hot. The plan is
             applied to the world: which police aircraft and boats exist,
             whether the aerostat is up, where the patrol goes, informant
             tips, bribed officials, contract crews and decoys in the air.
  wrap-up    the pilot's flight has ended (landed, busted, crashed); once the
             contract crews and decoys are done too, the night is scored and
             the next planning phase begins.
"""
from __future__ import annotations

import math
import random

from .ai_smuggler import AISmuggler, entry_and_exit
from .hq import AIRCRAFT_TIERS, ZONE_CENTRE, ZONE_FIELDS, RunResult, Season
from .jobs import new_id
from .maritime import random_drop_point

WRAP_TIMEOUT_S = 600.0


def zone_of(job) -> str | None:
    if job.is_airdrop:
        return "sea"
    for zone, codes in ZONE_FIELDS.items():
        if job.dest in codes:
            return zone
    return "west"


class NightDirector:
    def __init__(self, sess, rules: dict | None = None, runner_ai: str | None = "adaptive",
                 law_ai: str | None = "adaptive"):
        self.sess = sess
        self.season = Season(random.Random(sess.seed + 404), rules)
        self.runner_ai = runner_ai  # policy name, or None when a human boss is seated
        self.law_ai = law_ai
        self.phase = "planning"
        self.main: RunResult | None = None
        self.crews: list[AISmuggler] = []
        self.ended_at: float | None = None
        self._ai_mem = ({}, {})
        self._bot_rng = random.Random(sess.seed + 505)
        self._ai_planned = False
        sess.money = int(self.season.org.dirty)  # the organisation's war chest is the crew's cash

    # ------------------------------------------------------------ money sync
    def _pull(self) -> None:
        o = self.season.org
        o.dirty = int(self.sess.money)
        o.gear = set(self.sess.gear)
        keys = [t[0] for t in AIRCRAFT_TIERS]
        o.tier = max((keys.index(k) for k in self.sess.owned if k in keys), default=0)

    def _push(self) -> None:
        self.sess.money = int(self.season.org.dirty)
        self.sess.gear |= self.season.org.gear & {"scanner", "detector"}

    def order(self, side: str, name: str, **args) -> str | None:
        """An HQ order from a human (via Session.command) or a bot."""
        if self.season.phase == "over":
            return f"The season is over: {self.season.winner} ({self.season.reason})."
        if self.phase != "planning":
            return "HQ orders wait until the crew is back on the ground."
        self._pull()
        err = (self.season.runner_cmd if side == "runner" else self.season.law_cmd)(name, **args)
        self._push()
        return err

    def _run_ai(self) -> None:
        from .bots.hq import LAW_POLICIES, RUNNER_POLICIES

        self._pull()
        if self.runner_ai:
            RUNNER_POLICIES[self.runner_ai](self.season, self._bot_rng, self._ai_mem[0])
        if self.law_ai:
            LAW_POLICIES[self.law_ai](self.season, self._bot_rng, self._ai_mem[1])
        self._push()
        self._ai_planned = True

    # ------------------------------------------------------------ tick
    def tick(self, dt: float) -> None:
        sess = self.sess
        if self.season.phase == "over":
            return
        if self.phase == "planning":
            if not self._ai_planned:
                self._run_ai()
            if sess.phase == "flying" and sess.carrying_hot():
                self._begin()
        elif self.phase == "operation":
            self._track()
            if (sess.phase in ("crashed", "busted") or (sess.phase == "parked" and not sess.unloading)) \
                    and self.ended_at is None:
                self.ended_at = sess.time
                self._close_main()
            if self.ended_at is not None:
                busy = [a for a in self.crews if a.active]
                if not busy or sess.time - self.ended_at > WRAP_TIMEOUT_S:
                    self._finish()

    # ------------------------------------------------------------ operation
    def _begin(self) -> None:
        sess, ss = self.sess, self.season
        hot = [j for j in sess.active_jobs if j.hot]
        zone = zone_of(hot[0]) if hot else "west"
        self._pull()
        ss.org.route = zone
        plan = ss.start_operation()
        self.phase = "operation"
        self.ended_at = None
        self.main = RunResult("main", zone)
        self._paid_before = sess.money
        ps = sess.police
        ps.stock = {"heli": plan["funded"]["heli"], "interceptor": plan["funded"]["interceptor"],
                    "cutter": plan["cutters"]}
        ps.features |= {"interceptors", "cutters", "aerostat", "informants"}
        if plan["aerostat"]:
            ps.set_aerostat(True)
        sess.radio.encrypted = plan["encryption"]
        ps.no_customs = plan["no_customs"]
        if plan["patrol"] and ps.stock.get("heli", 0) > 0:
            ps.launch("heli", goal=ZONE_CENTRE[plan["patrol"]])
        # funded cutters start the night on picket off the coast, not in the harbour
        rng = self._bot_rng
        for _ in range(plan["cutters"]):
            cx, cy = ZONE_CENTRE["sea"]
            ps.stock["cutter"] -= 1
            sess.maritime.new_cutter(at=(cx + rng.uniform(-3000, 3000), cy + rng.uniform(-3000, 3000)))
        if plan["tip"] and hot:
            x, y = sess.job_xy(hot[0])
            rng = self._bot_rng
            ps.add_tip(x + rng.uniform(-1500, 1500), y + rng.uniform(-1500, 1500), 3000,
                       "informant: the organisation moves a load tonight", squawk=sess.squawk, target_id="runner")
        if plan["leak_patrol"] or plan.get("leak_aerostat"):
            sess.say(f"Your man in dispatch: patrol over the {plan['leak_patrol'] or 'nowhere'} tonight"
                     + (", and the balloon is up." if plan.get("leak_aerostat") else "."))
        # contract crews and decoys
        self.crews = []
        for k in range(plan["crews"] + plan["decoys"]):
            decoy = k >= plan["crews"]
            self.crews.append(self._spawn_run(decoy))
        sess.say(f"Night {plan['night']}: operation under way ({plan['crews']} crews, {plan['decoys']} decoys).")
        sess.law_say(f"Night {plan['night']}: operations begin.")

    def _spawn_run(self, decoy: bool) -> AISmuggler:
        sess = self.sess
        rng = sess.director.rng
        sess.director.serial += 1
        entry, exit_, hdg = entry_and_exit(rng)
        drop = random_drop_point(sess.world, rng, near=sess.maritime.cove)
        jid = new_id()
        a = AISmuggler(f"Runner-{sess.director.serial}", entry[0], entry[1], 150.0, hdg, drop, exit_, jid,
                       bales_left=0 if decoy else rng.randint(4, 6), hot=not decoy,
                       kind="decoy" if decoy else "crew")
        sess.smugglers.append(a)
        if not decoy:
            sess.maritime.new_gofast(drop, jid)
        return a

    def _track(self) -> None:
        sess, m = self.sess, self.main
        c = sess.police.cases.get("runner")
        if c and (c.detected_by or c.wanted):
            m.detected = True
        if any(u.sees_player and u.target_id == "runner" and u.faction == "police" for u in sess.police.units):
            m.intercepted = True

    def _close_main(self) -> None:
        sess, m = self.sess, self.main
        m.busted = sess.phase == "busted"
        m.crashed = sess.phase == "crashed"
        earned = max(0, sess.money - self._paid_before)
        m.delivered_value = earned
        if m.busted:
            m.seized_value = max(6000, sum(j.payout for j in sess.active_jobs if j.hot) * 3)

    def _finish(self) -> None:
        sess, ss = self.sess, self.season
        runs = [self.main]
        for a in self.crews:
            r = RunResult("decoy" if not a.hot else "crew", "sea")
            r.busted = a.state == "busted" and a.hot
            r.clean_stop = a.state == "busted" and not a.hot
            r.crashed = a.state == "crashed"
            boat = sess.maritime.gofast_for(a.job_id)
            r.boat_seized = bool(boat and boat.state == "seized")
            if a.hot and not (r.busted or r.crashed or r.boat_seized):
                r.delivered_value = int(ss.rules["run_payout"])
            if r.busted or r.boat_seized:
                r.seized_value = int(ss.rules["run_payout"]) * 3
            runs.append(r)
            if a.active:
                a.state = "escaped"
        self._pull()
        rep = ss.finish_night(runs, live=True)
        self._push()
        for line in rep.lines:
            sess.say(f"NEWS: {line}")
            sess.law_say(f"NEWS: {line}")
        for line in rep.runner_lines:
            sess.say(line)
        for line in rep.law_lines:
            sess.law_say(line)
        sess.police.no_customs = False
        self.phase = "planning"
        self.crews = []
        if ss.phase == "over":
            text = f"SEASON OVER - {'the Organisation' if ss.winner == 'runner' else 'the Task Force'} wins: {ss.reason}"
            sess.say(text)
            sess.law_say(text)
            return
        ss.next_night()
        self._push()  # tonight's overheads and standing bribes came off the books
        self._ai_planned = False
        sess.say(f"Night {ss.night} of {int(ss.rules['nights'])}: HQ is planning.")

    # ------------------------------------------------------------ views
    def view(self, side: str) -> dict:
        v = self.season.view(side)
        v["director_phase"] = self.phase
        return v


def main_zone_distance(sess) -> float:
    s = sess.state
    return min(math.hypot(s.x - x, s.y - y) for x, y in ZONE_CENTRE.values())
