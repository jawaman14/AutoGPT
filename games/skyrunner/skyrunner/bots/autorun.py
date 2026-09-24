"""AutoRunner: the pilot bot playing the career on its own.

Picks a job at the current field (hot ones first when the layer allows),
plans fuel, flies it, recovers from crashes and busts, repeats. Used by
`python -m skyrunner --watch` (watch the AI, low graphics recommended) and
as a soak test: hours of play without a human.
"""
from __future__ import annotations

from ..fdm import Controls
from ..roles import Role
from .pilot import PilotBot, mission_for, plan_fuel_lb


class AutoRunner:
    def __init__(self, sess, prefer_hot: bool = True):
        self.sess = sess
        self.prefer_hot = prefer_hot
        self.bot: PilotBot | None = None
        self.flights = 0
        self.log: list[str] = []
        self._wait = 0.0

    def _pick(self):
        s = self.sess
        board = s.boards.get(s.location, [])
        spec = s.spec
        seats = sum(1 for st in spec.stations if st.kind == "seat") - (1 if s.copilot else 0)

        def fits(j):
            pax = sum(1 for i in j.items if i.kind == "passenger")
            return pax <= seats and j.weight_lb < spec.mtow_lb * 0.25

        jobs = [j for j in board if fits(j)]
        if not jobs:
            return None
        return max(jobs, key=lambda j: (j.hot if self.prefer_hot else 0, j.payout))

    def step(self, dt: float) -> Controls | None:
        s = self.sess
        if s.phase in ("crashed", "busted"):
            self._wait += dt
            if self._wait > 4.0:
                self._wait = 0.0
                self.log.append(s.last_outcome)
                s.command(Role.PILOT, "confirm")
                self.bot = None
            return None
        if self.bot is not None and self.bot.phase != "done":
            return self.bot.step(dt)
        if not s.parked or s.unloading:
            return None
        self._wait += dt
        if self._wait < 3.0:  # a moment on the ground between flights
            return None
        self._wait = 0.0
        if not s.active_jobs:
            job = self._pick()
            if job is None:
                s.refresh_board(s.location)
                return None
            if s.accept_job(job):
                return None
        job = s.active_jobs[0]
        s.hire_loadmaster() if not s.loadout.compute().ok else None
        legs = mission_for(s, job, home=s.location)
        s.set_fuel(plan_fuel_lb(s, legs))
        self.bot = PilotBot(s, legs)
        self.flights += 1
        return self.bot.step(dt)
