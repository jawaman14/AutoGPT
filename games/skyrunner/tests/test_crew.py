"""Crew mechanics: commands & permissions, loading time, ferry fuel, airdrops,
transponder, autopilot, scanner, spotters, informants."""

import pytest

from skyrunner.controls import InputFrame
from skyrunner.game import Session
from skyrunner.jobs import airdrop_job
from skyrunner.maritime import random_drop_point
from skyrunner.roles import Mode, Role
from skyrunner.world import AIRFIELD_BY_CODE


@pytest.fixture()
def sess(world, jsbsim_root):
    return Session(world=world, jsbsim_root=jsbsim_root, seed=5)


def run(sess, secs, **kw):
    for _ in range(int(secs * 60)):
        sess.update(1 / 60, InputFrame(**kw))


def test_permissions_gate_commands(sess):
    ok, msg = sess.command(Role.CONTROLLER, "accept_job", job_id=1)
    assert not ok and "can't" in msg
    ok, _ = sess.command(Role.COPILOT, "transponder")  # pilot-only switch
    assert not ok
    ok, _ = sess.command(Role.PILOT, "transponder", on=False)
    assert ok and sess.transponder is False


def test_copilot_loads_faster(world, jsbsim_root):
    times = {}
    for crew in (None, "ai"):
        s = Session(world=world, jsbsim_root=jsbsim_root, seed=5, location="FRM")  # bush strip: no ramp crew
        s.set_copilot(crew)
        run(s, 0.3)
        job = next(j for j in s.boards["FRM"] if len(j.items) >= 2 and not any(i.kind == "passenger" for i in j.items))
        s.accept_job(job)
        t = 0.0
        while s.loadout.pending and t < 120:
            run(s, 0.5)
            t += 0.5
        times[crew] = t
    assert times["ai"] < times[None] * 0.75, times


def test_ferry_tank_fuel_moves_weight_and_cg(sess):
    run(sess, 0.3)
    sess.money = 20000
    assert sess.command(Role.PILOT, "buy_gear", name="ferry_tank")[0]
    run(sess, 20)
    assert sess.command(Role.PILOT, "fill_ferry", lb=200)[0]
    run(sess, 0.2)
    before = sess.fm.state()
    assert before.weight_lb > 1900
    sess.spawn_airborne(0, -9000, 90, 600, 95)
    sess.command(Role.PILOT, "set_fuel", lb=0)  # no-op in the air
    sess.fm.fdm["propulsion/tank[0]/contents-lbs"] = 40
    sess.fm.fdm["propulsion/tank[1]/contents-lbs"] = 40
    ferry0 = sess.loadout.ferry_fuel_lb()
    assert sess.command(Role.PILOT, "pump", on=True)[0]
    run(sess, 60)
    assert sess.loadout.ferry_fuel_lb() < ferry0 - 20  # solo electric pump ~25 lb/min
    assert sess.state.fuel_lb > 80 - 10
    hours, rng_km = sess.range_estimate()
    assert hours > 0 and rng_km > 50


def test_airdrop_to_boat_pays_at_the_cove(sess):
    sess.features.discard("cutters")
    run(sess, 0.3)
    drop = random_drop_point(sess.world, sess.rng, near=sess.maritime.cove)
    job = airdrop_job(AIRFIELD_BY_CODE["HAR"], drop, sess.rng, bales=3)
    sess.boards["HAR"].append(job)
    sess.set_copilot("ai")
    assert sess.accept_job(job) is None
    run(sess, 30)
    assert not sess.loadout.pending
    boat = sess.maritime.gofast_for(job.id)
    boat.x, boat.y, boat.state = drop[0] + 100, drop[1], "waiting"  # skip the 5 min boat ride out
    # teleport the aircraft over the rendezvous, slow and low; the co-pilot auto-kicks
    sess.spawn_airborne(drop[0] - 300, drop[1], 90, 120, 85)
    sess.mapper.controls.throttle = 0.7
    sess.command(Role.PILOT, "autopilot", on=True)
    for _ in range(60 * 20):
        sess.update(1 / 60, InputFrame())
    assert not sess._droppables()
    assert sess.phase == "flying"
    money = sess.money
    for _ in range(30 * 60 * 15):  # boat collects, runs for the cove
        sess.update(1 / 30, InputFrame())
        if job.resolved:
            break
    assert job.resolved and boat.state == "delivered"
    assert sess.money > money


def test_solo_kick_needs_autopilot(sess):
    run(sess, 0.3)
    drop = random_drop_point(sess.world, sess.rng, near=sess.maritime.cove)
    job = airdrop_job(AIRFIELD_BY_CODE["HAR"], drop, sess.rng, bales=2)
    sess.boards["HAR"].append(job)
    sess.accept_job(job)
    run(sess, 30)
    sess.spawn_airborne(drop[0], drop[1], 90, 150, 85)
    ok, msg = sess.command(Role.PILOT, "kick")
    assert not ok and "autopilot" in msg.lower()
    sess.command(Role.PILOT, "autopilot", on=True)
    assert sess.command(Role.PILOT, "kick", count=2)[0]
    run(sess, 5, held={"roll_left"})  # pilot is aft: stick input ignored, AP stays on
    assert sess.autopilot.engaged
    run(sess, 5)
    assert not sess._droppables()


def test_scanner_and_spotter_intel(sess):
    run(sess, 0.3)
    sess.money = 20000
    sess.command(Role.PILOT, "buy_gear", name="scanner")
    sess.command(Role.PILOT, "hire_spotter", code="VAL")
    sess.police.launch("heli", "VAL", goal=(2500, -3000))
    run(sess, 15)
    assert any("Hawk" in text for _, text in sess.scanner_log)
    assert any(k.startswith("Hawk") for k in sess.intel)
    sess.police.set_encryption(True) if "encryption" in sess.police.features else None


def test_informant_tip_marks_the_runner(sess):
    sess.features.add("informants")
    sess.police.features.add("informants")
    sess.rng.seed(1)
    run(sess, 0.3)
    tipped = False
    for _ in range(20):
        sess.location = "COV"
        sess.refresh_board("COV")
        sess.spawn_at("COV")
        hot = next((j for j in sess.boards["COV"] if j.hot), None)
        if hot is None:
            continue
        sess.accept_job(hot)
        if sess.police.tips:
            tipped = True
            break
        sess.drop_job(hot)
    assert tipped
    assert sess.police.case("runner").tipped


def test_police_mode_ai_runs_and_controller_commands(world, jsbsim_root):
    s = Session(world=world, jsbsim_root=jsbsim_root, seed=9, mode=Mode.POLICE, humans={Role.CONTROLLER: "me"})
    assert s.police.controller == "human"
    for _ in range(int(25 * 20)):
        s.update(1 / 20)
    assert s.smugglers, "an AI run should have been scheduled"
    ok, _ = s.command(Role.CONTROLLER, "launch", kind="interceptor", base="HAR")
    assert ok
    ok, _ = s.command(Role.CONTROLLER, "launch", kind="cutter", x=s.maritime.cove[0], y=s.maritime.cove[1])
    assert ok
    for _ in range(int(10 * 20)):
        s.update(1 / 20)
    falcon = next(u for u in s.police.units if u.kind == "interceptor")
    ok, _ = s.command(Role.CONTROLLER, "dispatch", unit=falcon.id, target=s.smugglers[0].id)
    assert ok and falcon.target_id == s.smugglers[0].id
    ok, _ = s.command(Role.PILOT, "launch", kind="heli")
    assert not ok


def test_transponder_off_gets_you_noticed(sess):
    run(sess, 0.3)
    har = AIRFIELD_BY_CODE["HAR"]
    sess.spawn_airborne(har.x + 2000, har.y - 4000, 90, 500, 100)
    sess.mapper.controls.throttle = 0.8
    sess.command(Role.PILOT, "autopilot", on=True)
    run(sess, 8)
    assert sess.police.suspicion == 0  # squawking: just traffic
    sess.command(Role.PILOT, "transponder", on=False)
    run(sess, 4)
    assert sess.police.suspicion >= 50 or sess.police.wanted  # squawk lost
    assert sess.police.detector() in ("LOCK", "PAINT")


def test_fuel_caches_at_shady_strips(sess):
    sess.spawn_at("QRY")
    before = sess.fm.fuel_lb()
    sess.set_fuel(before + 100)
    run(sess, 0.1)  # JSBSim totals the tanks on its next step
    assert sess.fm.fuel_lb() == pytest.approx(before, abs=1)  # nothing for sale at the quarry
    sess.fuel_caches["QRY"] = 150
    money = sess.money
    sess.set_fuel(before + 100)
    run(sess, 0.1)
    assert sess.fm.fuel_lb() == pytest.approx(before + 100, abs=1)
    assert sess.money == money and sess.fuel_caches["QRY"] == pytest.approx(50, abs=0.5)  # already paid for


def test_police_units_go_home_at_bingo_fuel(world):
    import random

    from skyrunner.police import ENDURANCE_S, PoliceSystem, Pursuer

    ps = PoliceSystem(world, random.Random(1))
    u = Pursuer("heli", 0, -6000, 500, 0.0, (-9000, -9500), speed=50, id="Hawk-1", goal=(0.0, -6000.0), state="goto")
    u.fuel_s = 2.0
    ps.units.append(u)
    t = 0.0
    for _ in range(100):
        t += 0.05
        ps.tick(0.05, t, [])
    assert u.state == "return"
    assert ENDURANCE_S["heli"] > 600


def test_calling_the_boat_gives_df_bearings(sess):
    run(sess, 0.3)
    drop = random_drop_point(sess.world, sess.rng, near=sess.maritime.cove)
    job = airdrop_job(AIRFIELD_BY_CODE["HAR"], drop, sess.rng, bales=2)
    sess.boards["HAR"].append(job)
    sess.accept_job(job)
    sess.spawn_airborne(drop[0], drop[1], 90, 150, 90)
    assert sess.command(Role.PILOT, "call_boat")[0]
    assert any("DF" in text for _, text in sess.law_log)
