"""A pilot bot that flies the real JSBSim aircraft through the Session.

It is not a cheat: it only reads what the pilot's instruments and eyes give
(own state, the map, detector/scanner/spotter intel the crew has) and moves
the same control surfaces a human does. That makes its results a fair probe of
the rules: if it can't get a loaded Cessna out of the quarry, a human will
struggle too; if it always escapes the police, the police are too weak.

Structure: a small flight director (heading->bank->aileron, vertical speed
->pitch->elevator, speed->throttle) under a phase machine:

  wait_load -> takeoff -> climb -> enroute(leg) -> [drop] -> approach -> flare
  -> rollout -> done

Approaches are planned against the terrain: both runway directions and a few
glide angles are tried, and the first final approach path that clears the
ground is used (plateaus and pits force steep ones).
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from ..fdm import FT, KT, Controls, FlightState
from ..roles import Role
from ..world import AIRFIELD_BY_CODE, Airfield

FPM = 0.00508  # m/s per ft/min
FINAL_HEIGHT_M = 320.0
CLIMB_MPS = 3.5  # climb rate the terrain planner assumes (loaded single, hot day)
TREE_ALLOWANCE_M = 22.0
CRUISE_FUEL_PPH = {"c172p": 55, "pa28": 55, "c182": 80, "c310": 170, "dhc6": 420}
CRUISE_KTS = {"c172p": 110, "pa28": 115, "c182": 135, "c310": 180, "dhc6": 150}  # height above the field where the final approach starts


def _clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def _wrap180(a: float) -> float:
    return (a + 180.0) % 360.0 - 180.0


def bearing(x0: float, y0: float, x1: float, y1: float) -> float:
    return math.degrees(math.atan2(x1 - x0, y1 - y0)) % 360.0


@dataclass
class Leg:
    kind: str  # "goto" | "drop" | "land"
    x: float
    y: float
    code: str | None = None  # airfield for "land"
    routed: bool = False


@dataclass
class Approach:
    af: Airfield
    hdg: float  # landing direction
    aim: tuple[float, float]  # touchdown aim point
    elev: float
    gamma: float  # glide angle, deg
    clear_m: float  # worst terrain clearance under the path

    def along_across(self, x: float, y: float) -> tuple[float, float]:
        """Distance to the aim point along the approach (+ve = still to go) and
        cross-track (+ve = right of the centreline)."""
        h = math.radians(self.hdg)
        ux, uy = math.sin(h), math.cos(h)
        dx, dy = x - self.aim[0], y - self.aim[1]
        return -(dx * ux + dy * uy), dx * uy - dy * ux

    def point(self, dist: float) -> tuple[float, float]:
        h = math.radians(self.hdg)
        return self.aim[0] - math.sin(h) * dist, self.aim[1] - math.cos(h) * dist

    def path_alt(self, dist: float) -> float:
        return self.elev + math.tan(math.radians(self.gamma)) * max(0.0, dist)


def plan_approach(world, af: Airfield, gear_h: float, roll_m: float = 180.0) -> Approach:
    """Pick landing direction, aim point and glide angle so the final clears the
    terrain and tree lines, preferring shallow paths and aim points near the
    threshold. Over a tree line the aim point moves down the runway, as long as
    what's left of it still stops the aircraft (roll_m, with margin)."""
    elev = world.airfield_elev(af)
    best = None
    aims = [f for f in (0.1, 0.18, 0.26, 0.34, 0.42) if af.length * (1 - f) > roll_m * 1.25] or [0.08]
    for gamma in (3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5):
        final_len = min(5000.0, FINAL_HEIGHT_M / math.tan(math.radians(gamma)))
        for frac in aims:
            for end in (0, 1):
                hdg = af.heading if end == 0 else (af.heading + 180) % 360
                tx, ty = af.threshold(end)
                h = math.radians(hdg)
                aim_d = min(max(25.0, af.length * frac), 150.0 + af.length * (frac - 0.1))
                aim = (tx + math.sin(h) * aim_d, ty + math.cos(h) * aim_d)
                ap = Approach(af, hdg, aim, elev + gear_h, gamma, 1e9)
                worst = 1e9
                d = aim_d + 10
                while d < final_len:
                    px, py = ap.point(d)
                    need = min(25.0, 3.0 + (d - aim_d) * 0.035)  # wheels just clear the fence
                    worst = min(worst, ap.path_alt(d) - gear_h - world.obstacle_top(px, py, 30.0) - need)
                    d += 20 if d < 800 else 60
                ap.clear_m = worst
                if worst >= 0:
                    return ap
                if best is None or worst > best.clear_m:
                    best = ap
    return best


def plan_departure(world, af: Airfield, roll_m: float, prefer: float | None = None) -> tuple[float, float]:
    """(takeoff heading, worst climb gradient needed) - the direction whose
    departure path is least blocked. Pits and tree lines make this matter."""
    elev = world.airfield_elev(af)
    best = None
    for end in (0, 1):
        hdg = af.heading if end == 0 else (af.heading + 180) % 360
        h = math.radians(hdg)
        sx, sy = af.threshold(end)
        worst = 0.0
        x = roll_m + 20
        while x < 3000:
            px, py = sx + math.sin(h) * x, sy + math.cos(h) * x
            if not af.contains(px, py, margin=4.0):
                rise = max(0.0, world.obstacle_top(px, py, 25.0) - elev)
                worst = max(worst, (rise + 10.0) / max(150.0, x - roll_m))
            x += 20 if x < 800 else 80
        facing = prefer is not None and abs(_wrap180(hdg - prefer)) < 90
        score = worst - (0.02 if facing else 0.0)  # don't backtrack for nothing
        if best is None or score < best[2]:
            best = (hdg, worst, score)
    return best[0], best[1]


@dataclass
class BotStyle:
    """Knobs that make bots differ (and let the sim probe tactics)."""
    agl_m: float = 110.0  # cruise height above the terrain
    evade_agl_m: float = 60.0
    cruise_throttle: float = 0.85
    transponder_off: bool = True  # when carrying something hot
    evade: bool = True  # duck and turn away from police it knows about
    bank_limit: float = 30.0
    skill: float = 1.0  # <1 adds control noise / sloppier flares
    route: bool = True  # plan valley routes (terrain masking) between legs
    lookahead_s: float = 75.0  # how far ahead the terrain planner starts climbing (shorter = lower, riskier)


@dataclass
class PilotBot:
    sess: object
    legs: list[Leg]
    style: BotStyle = field(default_factory=BotStyle)
    role: Role = Role.PILOT

    def __post_init__(self):
        self.phase = "wait_load"
        self.leg_i = 0
        self.pitch_base = 3.0
        self.elev_i = 0.0
        self.thr_i = 0.55
        self.t_phase = 0.0
        self.approach: Approach | None = None
        self.log: list[tuple[float, str]] = []
        self.outcome: str | None = None
        self.evading = 0.0
        self._kicked = False
        self._last_q = 0.0
        spec = self.sess.spec
        self.vy_kts = spec.approach_kts * 1.15
        self.vapp_kts = spec.approach_kts
        self.gear_h = self.sess.fm.mass.gear_height_ft * FT

    # ------------------------------------------------------------ helpers
    @property
    def leg(self) -> Leg | None:
        return self.legs[self.leg_i] if self.leg_i < len(self.legs) else None

    def _set(self, phase: str) -> None:
        self.phase = phase
        self.t_phase = 0.0
        self.log.append((self.sess.time, phase))

    def _attitude(self, c: Controls, s: FlightState, dt: float, bank_t: float, pitch_t: float) -> None:
        c.aileron = _clamp(0.04 * (bank_t - s.roll) - 0.012 * s.p_dps, -0.7, 0.7)
        # rate-limit the pitch command: a smooth target doesn't pump the phugoid
        prev = getattr(self, "_pitch_cmd", s.pitch)
        pitch_t = prev + _clamp(pitch_t - prev, -4.0 * dt, 4.0 * dt) if self.phase not in ("flare", "takeoff") else pitch_t
        self._pitch_cmd = pitch_t
        err = pitch_t - s.pitch
        self.elev_i = _clamp(self.elev_i - err * 0.02 * dt, -0.6, 0.6)
        # like a pilot: wind the steady push/pull into the trim wheel
        self.trim = _clamp(getattr(self, "trim", 0.0) + self.elev_i * 0.4 * dt, -1.0, 1.0)
        self.elev_i -= self.elev_i * 0.4 * dt
        c.pitch_trim = self.trim
        c.elevator = _clamp(-0.07 * err + 0.03 * s.q_dps + self.elev_i, -0.9, 0.9)

    def _bank_for(self, s: FlightState, hdg_t: float, limit: float | None = None) -> float:
        lim = limit or self.style.bank_limit
        return _clamp(_wrap180(hdg_t - s.heading) * 1.3, -lim, lim)

    def _pitch_for_vs(self, s: FlightState, dt: float, vs_t: float, min_ias: float) -> float:
        tas = max(20.0, s.ias_kts * KT)
        gamma_t = math.degrees(math.atan2(vs_t * FPM, tas))
        self.pitch_base = _clamp(self.pitch_base + (vs_t - s.vs_fpm) * 0.0009 * dt, -6.0, 12.0)
        pitch_t = _clamp(self.pitch_base + gamma_t, -10.0, 14.0)
        if s.ias_kts < min_ias:  # trade height for speed rather than stall
            pitch_t = min(pitch_t, s.pitch - (min_ias - s.ias_kts) * 0.6)
            self.pitch_base = min(self.pitch_base, pitch_t)
        return pitch_t

    def _throttle_for(self, s: FlightState, dt: float, ias_t: float, vs_t: float | None = None) -> float:
        """Speed on throttle; with vs_t it also feeds the climb/sink error (a crude
        total-energy controller: below the path and slow means more power)."""
        err = ias_t - s.ias_kts
        vs_err = 0.0 if vs_t is None else _clamp(vs_t - s.vs_fpm, -800.0, 800.0)
        self.thr_i = _clamp(self.thr_i + (err * 0.006 + vs_err * 0.00012) * dt, 0.0, 1.0)
        return _clamp(self.thr_i + err * 0.035 + vs_err * 0.0006, 0.0, 1.0)

    def _terrain_ahead(self, s: FlightState, secs: float = 25.0) -> float:
        """Altitude floor from the terrain ahead, allowing for how fast this
        aircraft can actually climb: a ridge 60 s out that needs more than
        CLIMB_MPS to top means start climbing now. Cached for 0.5 s."""
        key = round(self.sess.time * 2), secs
        if getattr(self, "_ta_key", None) == key:
            return self._ta_val
        vx, vy = s.vx, s.vy
        if math.hypot(vx, vy) < 10:
            h = math.radians(s.heading)
            vx, vy = math.sin(h) * 50, math.cos(h) * 50
        horizon = max(secs, self.style.lookahead_s) if secs >= 20 else secs
        t = np.arange(0.0, horizon + 0.1, 2.0)
        g = np.maximum(self.sess.world.heights_many(s.x + vx * t, s.y + vy * t), 0.0)
        # also a little either side: we'll be turning
        px, py = -vy, vx
        n = max(1e-6, math.hypot(px, py))
        for side in (-1, 1):
            ox, oy = px / n * 150 * side, py / n * 150 * side
            g = np.maximum(g, np.maximum(self.sess.world.heights_many(s.x + vx * t + ox, s.y + vy * t + oy), 0.0))
        g = g + np.where(g > 6.0, TREE_ALLOWANCE_M, 0.0)  # forests don't show in the height map
        need = g - CLIMB_MPS * t
        self._ta_key, self._ta_val = key, float(max(need.max(), g[:3].max()))
        return self._ta_val

    def _need_along(self, s: FlightState, hdg: float, horizon: float = 75.0) -> float:
        """Altitude needed now to clear the terrain on heading `hdg`, given CLIMB_MPS."""
        sp = max(40.0, math.hypot(s.vx, s.vy))
        h = math.radians(hdg)
        vx, vy = math.sin(h) * sp, math.cos(h) * sp
        t = np.arange(0.0, horizon + 0.1, 2.5)
        w = self.sess.world
        g = np.maximum(w.heights_many(s.x + vx * t, s.y + vy * t), 0.0)
        # the turn onto this heading swings us up to a turn radius sideways
        r = sp * sp / (9.81 * math.tan(math.radians(self.style.bank_limit)))
        for side in (-1.0, 1.0):
            ox, oy = math.cos(h) * r * side, -math.sin(h) * r * side
            g = np.maximum(g, np.maximum(w.heights_many(s.x + ox + vx * t, s.y + oy + vy * t), 0.0))
        g = g + np.where(g > 6.0, TREE_ALLOWANCE_M, 0.0)
        return float((g - CLIMB_MPS * 0.8 * t).max())

    def _safe_heading(self, s: FlightState, desired: float) -> float:
        """The heading nearest `desired` whose terrain we can out-climb; if none,
        the one with the lowest terrain (turn away from the ridge and climb)."""
        key = round(self.sess.time)
        if getattr(self, "_sh_key", None) == (key, round(desired)):
            return self._sh_val
        margin = s.alt - min(self.style.agl_m, 80.0)
        best, best_need = desired, None
        for off in (0, 20, -20, 40, -40, 60, -60, 90, -90, 120, -120, 150, -150, 180):
            hdg = (desired + off) % 360
            need = self._need_along(s, hdg)
            if need <= margin:
                best, best_need = hdg, need
                break
            if best_need is None or need < best_need:
                best, best_need = hdg, need
        self._sh_key, self._sh_val = (key, round(desired)), best
        return best

    def _threat(self, s: FlightState):
        """Closest police unit the crew knows about (intel, detector, eyes)."""
        sess = self.sess
        best = None
        for unit, (t, x, y, _src) in sess.intel.items():
            if t <= sess.time:
                d = math.hypot(x - s.x, y - s.y)
                if best is None or d < best[2]:
                    best = (x, y, d)
        for u in sess.police.units:  # what you can see out of the window
            if u.faction == "police" and u.state != "crashed":
                d = math.dist((u.x, u.y, u.z), (s.x, s.y, s.alt))
                if d < 4500 and (best is None or d < best[2]):
                    best = (u.x, u.y, d)
        det = sess.police.detector() if "detector" in sess.gear else ""
        return best, det

    # ------------------------------------------------------------ main
    def step(self, dt: float) -> Controls | None:
        sess = self.sess
        s = sess.state
        self.t_phase += dt
        if sess.phase in ("crashed", "busted"):
            self.outcome = sess.phase
            self.phase = "done"
            return None
        if self.phase == "done":
            return None
        c = Controls(flaps=0.0, throttle=0.0)
        getattr(self, f"_p_{self.phase}")(c, s, dt)
        return c

    def _p_wait_load(self, c, s, dt):
        c.brake = 1.0
        # a squawk that vanishes on radar is the classic tell: go dark on the ramp
        if sess_hot(self.sess) and self.style.transponder_off and self.sess.transponder:
            self.sess.command(self.role, "transponder", on=False)
        if not self.sess.loadout.busy():
            self._begin_departure(s)

    def _begin_departure(self, s: FlightState) -> None:
        sess = self.sess
        af = sess.airfield or sess.world.nearest_airfield(s.x, s.y)[0]
        roll = sess.spec.est_landing_roll(s.weight_lb, sess.world.airfield_elev(af)) * 1.35
        hdg, self.departure_gradient = plan_departure(sess.world, af, roll, prefer=s.heading)
        self.runway_hdg = hdg
        self.dep_af = af
        along, _ = af.to_local(s.x, s.y)
        facing = 1 if abs(_wrap180(s.heading - af.heading)) < 90 else -1
        want = 1 if abs(_wrap180(hdg - af.heading)) < 90 else -1
        # start of the takeoff run: the threshold behind us in the chosen direction
        start_along = -want * (af.length / 2 - 12)
        if want == facing and abs(along - start_along) < 40:
            self._set("takeoff")
        else:
            self.taxi_goal = start_along
            self._set("taxi")

    def _p_taxi(self, c, s, dt):
        """Backtrack along the runway to the start of the takeoff run, then turn
        round onto the takeoff heading."""
        af = self.dep_af
        along, across = af.to_local(s.x, s.y)
        to_go = self.taxi_goal - along
        if not getattr(self, "taxi_turning", False):
            dir_sign = 1 if to_go > 0 else -1
            taxi_hdg = af.heading if dir_sign > 0 else (af.heading + 180) % 360
            err = _wrap180(taxi_hdg - s.heading)
            if abs(err) > 90 and s.gs_kts < 1.0 and abs(to_go) >= 8:
                c.brake = 1.0
                if self.sess.turnaround_t <= 0:
                    self.sess.command(self.role, "turn_around")
                return
            if abs(to_go) < 8:
                self.taxi_turning = True
                self.thr_i = 0.4
            else:
                target_speed = 12.0 if abs(err) < 20 and abs(to_go) > 60 else 5.0
                # hug the left edge: the right-hand pivot at the end swings us back across
                across_t = 0.0
                c.rudder = _clamp(0.06 * err - 0.05 * (across - across_t) * dir_sign, -1, 1)
                c.throttle = _clamp(0.25 + (target_speed - s.gs_kts) * 0.05, 0.0, 0.6)
                c.brake = 1.0 if s.gs_kts > target_speed + 3 else 0.0
                return
        # at the start of the run: stop, and push her round by hand if needed
        c.throttle = 0.0
        c.brake = 1.0
        if self.sess.turnaround_t > 0 or s.gs_kts > 1.0:
            return
        if abs(_wrap180(self.runway_hdg - s.heading)) > 90:
            self.sess.command(self.role, "turn_around")
            return
        self.taxi_turning = False
        self._set("takeoff")
        if self.t_phase > 300:
            self._fail("stuck taxiing")

    def _p_takeoff(self, c, s, dt):
        af = getattr(self, "dep_af", None) or self.sess.airfield or self.sess.world.nearest_airfield(s.x, s.y)[0]
        c.throttle = 1.0
        c.flaps = 0.33 if af.length < 600 else 0.0
        _, across = af.to_local(s.x, s.y)
        hdg_err = _wrap180(self.runway_hdg - s.heading)
        side = 1 if abs(_wrap180(af.heading - self.runway_hdg)) < 90 else -1
        c.rudder = _clamp(0.12 * hdg_err - 0.02 * across * side, -1, 1)
        pitch_t = 0.0
        short = af.length < 600
        vr = self.sess.spec.rotate_kts * (0.88 if short else 1.0) * math.sqrt(max(0.6, s.weight_lb / self.sess.spec.mtow_lb))
        if s.ias_kts >= vr:
            pitch_t = (11.0 if short else 9.0) if self.sess.spec.visual.engines == 1 else 7.0
        if s.on_ground and pitch_t == 0.0:
            c.elevator = 0.0
            c.aileron = 0.0
        else:
            self._attitude(c, s, dt, 0.0, pitch_t)
        if not s.on_ground and s.agl > 8:
            if sess_hot(self.sess) and self.style.transponder_off and self.sess.transponder:
                self.sess.command(self.role, "transponder", on=False)
            self._set("climb")
        if self.t_phase > 90:
            self._fail("never got airborne")

    def _p_climb(self, c, s, dt):
        c.throttle = 1.0
        c.flaps = 0.33 if s.ias_kts < self.sess.spec.rotate_kts + 12 and s.agl < 60 else 0.0
        # obstacle climb at Vx until clear of the trees, then Vy
        low = s.agl < 60
        heavy = math.sqrt(max(0.6, s.weight_lb / self.sess.spec.mtow_lb))
        v_climb = self.vapp_kts * 0.88 * heavy if low else self.vy_kts
        pitch_t = _clamp(8.0 + (s.ias_kts - v_climb) * 0.5, 8.5 if s.agl < 30 else 0.0, 13.0)
        hdg_t = self.runway_hdg if s.agl < 60 else self._safe_heading(s, bearing(s.x, s.y, self.leg.x, self.leg.y))
        self._attitude(c, s, dt, self._bank_for(s, hdg_t, 15 if s.agl < 100 else None), pitch_t)
        want = self._terrain_ahead(s) + self.style.agl_m
        if s.alt >= want - 10 and s.agl > 60:
            self.pitch_base = s.pitch
            self._set("enroute")

    def _route_to(self, s: FlightState, leg: Leg) -> None:
        """Before a leg: thread a valley route to its entry point (the approach's
        intermediate fix for a landing) and insert it as waypoints."""
        from .route import plan_route

        target = (leg.x, leg.y)
        if leg.kind == "land":
            af = AIRFIELD_BY_CODE[leg.code]
            roll = self.sess.spec.est_landing_roll(s.weight_lb, self.sess.world.airfield_elev(af))
            self.approach = plan_approach(self.sess.world, af, self.gear_h, roll)
            target = self.approach.point(self._if_dist(self.approach) + 800)
        pts = plan_route(self.sess.world, (s.x, s.y), target)[:-1]
        if math.dist((s.x, s.y), target) < 3000:
            pts = []
        self.legs[self.leg_i:self.leg_i] = [Leg("goto", x, y) for x, y in pts]
        leg.routed = True

    def _p_enroute(self, c, s, dt):
        leg = self.leg
        if leg is None:
            return self._set("done")
        if self.style.route and leg.kind != "goto" and not getattr(leg, "routed", False):
            self._route_to(s, leg)
            leg = self.leg
        d = math.hypot(leg.x - s.x, leg.y - s.y)
        hdg_t = bearing(s.x, s.y, leg.x, leg.y)
        agl = self.style.agl_m
        throttle = self.style.cruise_throttle
        threat, det = self._threat(s) if self.style.evade else (None, "")
        if threat and threat[2] < 5000 or det == "LOCK":
            self.evading = 20.0
        if self.evading > 0:
            self.evading -= dt
            agl = self.style.evade_agl_m
            throttle = 1.0
            if threat:
                away = bearing(threat[0], threat[1], s.x, s.y)
                hdg_t = hdg_t + _wrap180(away - hdg_t) * 0.6
        if leg.kind == "drop" and d < 3500:
            agl, throttle = 110.0, 0.6
        hdg_t = self._safe_heading(s, hdg_t)
        alt_t = self._terrain_ahead(s) + agl
        vs_t = _clamp((alt_t - s.alt) * 12.0, -900.0, 1200.0)
        if alt_t - s.alt > 30:
            throttle = 1.0
        pitch_t = self._pitch_for_vs(s, dt, vs_t, self.vapp_kts * 1.1)
        self._attitude(c, s, dt, self._bank_for(s, hdg_t), pitch_t)
        c.throttle = throttle
        turn_r = (s.ias_kts * KT) ** 2 / (9.81 * math.tan(math.radians(self.style.bank_limit)))
        if leg.kind == "goto" and d < max(600.0, 1.5 * turn_r):
            self.leg_i += 1
        elif leg.kind == "drop" and d < 900:
            self._set("drop")
        elif leg.kind == "land":
            if self.approach is None:
                af = AIRFIELD_BY_CODE[leg.code]
                roll = self.sess.spec.est_landing_roll(self.sess.state.weight_lb, self.sess.world.airfield_elev(af))
                self.approach = plan_approach(self.sess.world, af, self.gear_h, roll)
            ap = self.approach
            along, across = ap.along_across(s.x, s.y)
            ifx, ify = ap.point(self._if_dist(ap))
            if math.hypot(ifx - s.x, ify - s.y) < 700 or (0 < along < self._if_dist(ap) + 500 and abs(across) < 300
                                                          and abs(_wrap180(ap.hdg - s.heading)) < 45):
                self.established = False
                self._set("approach")
            else:
                # head for the intermediate fix on the extended centreline
                hdg_t = bearing(s.x, s.y, ifx, ify)
                self._attitude(c, s, dt, self._bank_for(s, hdg_t), pitch_t)

    def _p_drop(self, c, s, dt):
        sess = self.sess
        leg = self.leg
        d = math.hypot(leg.x - s.x, leg.y - s.y)
        remaining = len(sess._droppables())
        if remaining == 0 and sess.kick_queue == 0:
            sess.command(self.role, "autopilot", on=False) if sess.autopilot.engaged else None
            self.leg_i += 1
            self._set("enroute")
            return
        # orbit the rendezvous clockwise at ~500 m, 110 m above the water, ~95 kt
        r = 500.0
        tangent = bearing(leg.x, leg.y, s.x, s.y) + 90.0
        hdg_t = tangent + _clamp((d - r) * 0.12, -60, 60)
        if d > 1500:
            hdg_t = bearing(s.x, s.y, leg.x, leg.y)
        alt_t = self._terrain_ahead(s, 10) + 110.0
        vs_t = _clamp((alt_t - s.alt) * 12.0, -700.0, 900.0)
        pitch_t = self._pitch_for_vs(s, dt, vs_t, self.vapp_kts * 1.1)
        self._attitude(c, s, dt, self._bank_for(s, hdg_t), pitch_t)
        c.throttle = self._throttle_for(s, dt, min(95.0, self.vapp_kts * 1.45))
        if d < 450 and sess.kick_queue == 0 and not sess.copilot:
            # solo: autopilot on, go aft and kick them all
            if not sess.autopilot.engaged:
                sess.command(self.role, "autopilot", on=True)
            sess.command(self.role, "kick", count=remaining)
        if self.t_phase > 400:
            self._fail("couldn't get the bales out")

    @staticmethod
    def _if_dist(ap: Approach) -> float:
        return min(5000.0, FINAL_HEIGHT_M / math.tan(math.radians(ap.gamma))) + 1500.0

    def _p_approach(self, c, s, dt):
        ap = self.approach
        along, across = ap.along_across(s.x, s.y)
        spec = self.sess.spec
        if abs(across) < 40:
            self.established = True
        hdg_t = self._track_centreline(s, ap, across, 25.0 if along > 1500 else 10.0)
        bank_lim = 30.0 if along > 1500 else 15.0
        # vertical: follow the glide path once lined up, never below the terrain ahead
        gp = ap.path_alt(along if self.established else max(along, self._final_len(ap)))
        floor = self._terrain_ahead(s, 8) + 30.0 if along > 800 else -1e9
        alt_t = max(gp, floor) if along > 0 else ap.elev
        gs_mps = max(25.0, s.gs_kts * KT)
        on_path = alt_t == gp and self.established
        vs_nom = -gs_mps * math.tan(math.radians(ap.gamma)) / FPM if on_path else 0.0
        vs_t = _clamp(vs_nom + (alt_t - s.alt) * 15.0, -1400.0, 900.0)
        # approach speed scales with sqrt(weight); short strips get the short-field number
        heavy = math.sqrt(max(0.6, s.weight_lb / spec.mtow_lb))
        vref = self.vapp_kts * heavy * (1.0 + (0.1 if along > 2500 else 0.0)) * (0.93 if ap.af.length < 500 else 1.0)
        pitch_t = self._pitch_for_vs(s, dt, vs_t, self.vapp_kts * heavy * 0.82)
        self._attitude(c, s, dt, self._bank_for(s, hdg_t, bank_lim), pitch_t)
        c.throttle = self._throttle_for(s, dt, vref, vs_t)
        # too fast on a steep final with the power already off: forward slip
        # (crossed controls; the heading loop banks against the rudder)
        if c.throttle < 0.05 and along < 2000 and self.established:
            self.slip = _clamp(getattr(self, "slip", 0.0) + (s.ias_kts - vref - 1.0) * 0.05 * dt, 0.0, 0.9)
        else:
            self.slip = max(0.0, getattr(self, "slip", 0.0) - dt)
        c.rudder = self.slip
        if s.ias_kts < spec.max_flap_kts:
            c.flaps = 1.0 if along < 2200 else 0.66
        wheels = s.alt - self.gear_h - (ap.elev - self.gear_h)  # above the runway, not the terrain below
        sink = max(0.0, -s.vs_fpm * FPM)
        flare_h = 1.0 + 0.9 * sink
        ahead = [ap.point(along - k) for k in (40.0, 80.0, 120.0) if along - k > 0]
        ahead = [p for p in ahead if not ap.af.contains(*p, margin=5.0)]
        cliff = max((self.sess.world.obstacle_top(*p, 20.0) for p in ahead), default=-1e9)
        if wheels < flare_h and along < 400 and cliff < s.alt - self.gear_h - 1.0:
            self._set("flare")
        elif cliff > s.alt - self.gear_h - 3.0 and along > 60:
            return self._go_around("low on the approach")
        if along < -ap.af.length * 0.5 or (along < 900 and (abs(across) > 60 or s.alt - gp > 60)):
            self._go_around("unstable approach")

    def _final_len(self, ap: Approach) -> float:
        return min(5000.0, FINAL_HEIGHT_M / math.tan(math.radians(ap.gamma)))

    def _track_centreline(self, s, ap: Approach, across: float, v_max: float) -> float:
        """Heading that gives a sideways speed proportional to the cross-track error."""
        gs = max(20.0, s.gs_kts * KT)
        v_lat = _clamp(-across * 0.12, -v_max, v_max)
        return ap.hdg + math.degrees(math.asin(_clamp(v_lat / gs, -0.7, 0.7)))

    def _p_flare(self, c, s, dt):
        ap = self.approach
        along, across = ap.along_across(s.x, s.y)
        c.flaps = 1.0
        c.throttle = 0.0
        wheels = s.alt - ap.elev
        vs_t = -max(200.0, min(350.0, wheels * 80.0))
        pitch_t = _clamp(s.pitch + (vs_t - s.vs_fpm) * 0.012, -2.0, 12.0)
        self._attitude(c, s, dt, self._bank_for(s, self._track_centreline(s, ap, across, 3.0), 8.0), pitch_t)
        c.rudder = _clamp(0.05 * _wrap180(ap.hdg - s.heading), -0.5, 0.5)
        if s.on_ground:
            self._set("rollout")
        elif along < -ap.af.length * 0.45:
            self._go_around("floated long")

    def _p_rollout(self, c, s, dt):
        ap = self.approach
        _, across = ap.along_across(s.x, s.y)
        c.flaps = 0.0 if self.t_phase > 0.2 else 1.0
        c.throttle = 0.0
        c.elevator = 0.0
        c.aileron = 0.0
        c.brake = 1.0 if self.t_phase > 0.3 else 0.0
        c.rudder = _clamp(0.12 * _wrap180(ap.hdg - s.heading) - 0.03 * across, -1, 1)
        if self.sess.phase == "parked" and s.gs_kts < 1.0:
            self.outcome = "landed"
            self.leg_i += 1
            self.approach = None
            if self.leg is None:
                self._set("done")
            else:
                self._begin_departure(s)
        elif not s.on_ground and s.agl > 4:
            self._set("flare")

    def _go_around(self, why: str) -> None:
        self.log.append((self.sess.time, f"go-around: {why}"))
        self.go_arounds = getattr(self, "go_arounds", 0) + 1
        if self.go_arounds > 3:
            return self._fail("too many go-arounds")
        self.approach = None
        self.runway_hdg = self.sess.state.heading
        self._set("climb")

    def _fail(self, why: str) -> None:
        self.outcome = f"gave up: {why}"
        self.log.append((self.sess.time, self.outcome))
        self.phase = "done"


def plan_fuel_lb(sess, legs: list[Leg], reserve_h: float = 0.6) -> float:
    """Fuel for the route plus a reserve: what a sensible pilot loads for a
    short strip, instead of brimming the tanks."""
    s = sess.state
    x, y = s.x, s.y
    dist = 0.0
    for leg in legs:
        dist += math.hypot(leg.x - x, leg.y - y)
        x, y = leg.x, leg.y
    key = sess.aircraft_key
    hours = dist / 1852.0 / CRUISE_KTS.get(key, 110) * 1.3 + reserve_h + (0.15 if any(lg.kind == "drop" for lg in legs) else 0.0)
    return min(sess.loadout.mass.fuel_capacity_lb, hours * CRUISE_FUEL_PPH.get(key, 60))


def sess_hot(sess) -> bool:
    return any(i.hot for i in sess.loadout.items.values())


def mission_for(sess, job, home: str | None = None) -> list[Leg]:
    """Legs for one job: an airdrop goes to the boat then home, anything else
    flies to its destination."""
    if job.is_airdrop:
        home = home or sess.location
        af = AIRFIELD_BY_CODE[home]
        return [Leg("drop", job.drop_point[0], job.drop_point[1]), Leg("land", af.x, af.y, home)]
    af = AIRFIELD_BY_CODE[job.dest]
    return [Leg("land", af.x, af.y, job.dest)]


def fly(sess, bot: PilotBot, max_time: float = 1800.0, dt: float = 1 / 30, on_frame=None) -> str:
    """Run the session until the bot is done (headless). Returns the outcome."""
    t_end = sess.time + max_time
    while sess.time < t_end:
        c = bot.step(dt)
        if bot.phase == "done" and bot.outcome is not None:
            break
        sess.update(dt, controls=c)
        if on_frame:
            on_frame(sess)
    if bot.outcome is None:
        bot.outcome = "timeout"
    return bot.outcome
