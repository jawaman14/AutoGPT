"""Pilot bot, route/approach/departure planners, live HQ nights, police pilot seat."""
import math

import pytest

from skyrunner.bots.pilot import Leg, PilotBot, fly, mission_for, plan_approach, plan_departure, plan_fuel_lb
from skyrunner.bots.route import plan_route
from skyrunner.game import SANDBOX_FEATURES, Session
from skyrunner.net.snapshot import build_snapshot
from skyrunner.roles import Mode, Role
from skyrunner.world import AIRFIELD_BY_CODE, AIRFIELDS


@pytest.mark.parametrize("code", [a.code for a in AIRFIELDS])
def test_every_strip_has_a_clear_approach(world, code):
    ap = plan_approach(world, AIRFIELD_BY_CODE[code], 1.2, 120.0)
    assert ap.clear_m >= 0, f"{code}: no approach path clears the terrain"
    assert ap.gamma <= 9.5


def test_departures_leave_downhill(world):
    # the quarry only opens to the north-west (the haul road); Pine Ridge's uphill end is a hillside
    assert plan_departure(world, AIRFIELD_BY_CODE["QRY"], 160)[0] == 340
    assert plan_departure(world, AIRFIELD_BY_CODE["PNR"], 160)[0] == 45


def test_route_planner_threads_low_ground(world):
    frm, qry = AIRFIELD_BY_CODE["FRM"], AIRFIELD_BY_CODE["QRY"]
    pts = plan_route(world, (frm.x, frm.y), (qry.x, qry.y))
    assert pts[-1] == (qry.x, qry.y) and len(pts) >= 3
    straight_max = max(world.height(frm.x + (qry.x - frm.x) * t / 20, frm.y + (qry.y - frm.y) * t / 20) for t in range(21))
    route_max = max(world.height(x, y) for x, y in pts)
    assert route_max <= straight_max + 1


def test_bot_flies_and_lands_a_cessna(jsbsim_root):
    s = Session(seed=5, location="HAR", jsbsim_root=jsbsim_root, features=set())
    s.police.tick = lambda *a, **k: {}
    val = AIRFIELD_BY_CODE["VAL"]
    bot = PilotBot(s, [Leg("land", val.x, val.y, "VAL")])
    assert fly(s, bot, 900) == "landed"
    assert s.phase == "parked" and s.location == "VAL"
    assert s.log.max_touchdown_fpm < s.spec.gear_limit_fpm


def test_turn_around_pushes_the_aircraft_round(jsbsim_root):
    s = Session(seed=5, location="PNR", jsbsim_root=jsbsim_root, features=set())
    h0 = s.state.heading
    assert s.command(Role.PILOT, "turn_around") == (True, "ok")
    for _ in range(int(21 * 30)):
        s.update(1 / 30)
    assert abs(((s.state.heading - h0) % 360) - 180) < 3
    assert s.parked


def test_fuel_plan_is_route_plus_reserve(jsbsim_root):
    s = Session(seed=5, location="FRM", jsbsim_root=jsbsim_root, features=set())
    af = AIRFIELD_BY_CODE["EGL"]
    fuel = plan_fuel_lb(s, [Leg("land", af.x, af.y, "EGL")])
    assert 30 < fuel < s.loadout.mass.fuel_capacity_lb * 0.6


def test_live_night_with_hq(jsbsim_root):
    """A whole night in the real Session: AI chief plans, the bot flies an
    airdrop, the season scores it and moves to night 2."""
    s = Session(seed=9, location="FRM", jsbsim_root=jsbsim_root, features=set(SANDBOX_FEATURES) | {"hq"})
    s.set_copilot("ai")
    s.update(1 / 30)
    assert s.nights.season.night == 1 and s.nights.phase == "planning"
    assert s.command(Role.PILOT, "hq", order="route", zone="sea") == (True, "ok")
    job = next(j for j in s.boards["FRM"] if j.hot)
    assert s.accept_job(job) is None
    s.loadout.pending.clear()
    s.fm.apply_loadout(s.loadout)
    legs = mission_for(s, job)
    s.set_fuel(plan_fuel_lb(s, legs))
    fly(s, PilotBot(s, legs), 2400)
    t = s.time
    while s.nights.phase != "planning" and s.time - t < 900:
        s.update(0.1)
    assert s.nights.season.night == 2 or s.nights.season.phase == "over"
    snap = build_snapshot(s, Role.PILOT)
    assert snap["season"]["night"] >= 1 and "org" in snap["season"]
    assert "org" not in build_snapshot(s, Role.CONTROLLER)["season"]


def test_police_pilot_claims_flies_and_sees_only_what_is_in_sight(jsbsim_root):
    s = Session(mode=Mode.VERSUS, seed=4, jsbsim_root=jsbsim_root, humans={Role.INTERCEPTOR: "Evelyn"})
    assert s.command(Role.INTERCEPTOR, "claim_unit", kind="interceptor") == (True, "ok")
    for _ in range(30 * 12):
        s.update(1 / 30)
    me = next(u for u in s.police.units if u.pilot == "interceptor")
    s.set_pilot_input("interceptor", 0.6, 0.5, 1.0)
    h0, z0 = me.heading, me.z
    for _ in range(30 * 5):
        s.update(1 / 30)
    assert ((me.heading - h0) % 360) > 5 and me.z > z0 + 20
    snap = build_snapshot(s, Role.INTERCEPTOR)
    assert snap["me"]["id"] == me.id
    # the runner is parked miles away behind terrain: not in the visual list
    assert not [v for v in snap["visual"] if v["kind"] == "runner"]
    assert s.command(Role.INTERCEPTOR, "release_unit") == (True, "ok")
    assert me.pilot is None


def test_pilot_cannot_claim_police_units(jsbsim_root):
    s = Session(mode=Mode.VERSUS, seed=4, jsbsim_root=jsbsim_root)
    ok, msg = s.command(Role.PILOT, "claim_unit")
    assert not ok and "can't" in msg


def test_route_distance_sanity(world):
    har, isl = AIRFIELD_BY_CODE["HAR"], AIRFIELD_BY_CODE["ISL"]
    pts = plan_route(world, (har.x, har.y), (isl.x, isl.y))
    length = sum(math.dist(a, b) for a, b in zip([(har.x, har.y)] + pts[:-1], pts))
    assert length < 2.0 * math.dist((har.x, har.y), (isl.x, isl.y))


def test_hot_load_unloads_slowly_and_can_be_raided(jsbsim_root):
    from skyrunner.police import Pursuer

    def landed_at_quarry():
        s = Session(seed=3, location="QRY", jsbsim_root=jsbsim_root, features=set(SANDBOX_FEATURES))
        s.update(1 / 30)
        job = next(j for j in s.boards["QRY"] if j.hot and not j.is_airdrop)
        job.dest = "QRY"  # pretend we just flew it in
        s.accept_job(job)
        s.loadout.pending.clear()
        s._arrive(s.airfield, s.state)
        return s, job

    s, job = landed_at_quarry()
    assert s.unloading == [job] and job in s.active_jobs
    money = s.money
    for _ in range(int(62 * 10)):
        s.update(0.1)
    assert not s.unloading and job not in s.active_jobs and s.money > money
    # same again, but a police helicopter turns up
    s, job = landed_at_quarry()
    af = AIRFIELD_BY_CODE["QRY"]
    s.police.units.append(Pursuer("heli", af.x + 800, af.y, s.state.alt + 150, 0.0, (0, 0), id="Hawk-9"))
    for _ in range(20):
        s.update(0.1)
    assert s.phase == "busted" and "raided" in s.last_outcome
