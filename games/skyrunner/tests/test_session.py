import pytest

from skyrunner.controls import InputFrame
from skyrunner.game import Session
from skyrunner.world import AIRFIELD_BY_CODE


@pytest.fixture()
def sess(world, jsbsim_root):
    return Session(world=world, jsbsim_root=jsbsim_root, seed=3)


def idle(sess, secs, **held):
    for _ in range(int(secs * 60)):
        sess.update(1 / 60, InputFrame(held=set(held.get("held", ()))))


def test_starts_parked_with_jobs(sess):
    idle(sess, 1)
    assert sess.parked and sess.location == "HAR"
    assert sess.boards["HAR"]


def test_accept_job_loads_items(sess):
    idle(sess, 0.5)
    job = next(j for j in sess.boards["HAR"] if j.weight_lb < 250)
    before = sess.fm.state().weight_lb
    assert sess.accept_job(job) is None
    assert sess.loadout.pending  # the crew has to carry it in
    idle(sess, 0.2)
    assert sess.fm.state().weight_lb == pytest.approx(before, abs=5)
    idle(sess, 30)
    assert not sess.loadout.pending
    assert sess.fm.state().weight_lb == pytest.approx(before + job.weight_lb, abs=5)


def test_cannot_depart_with_cargo_on_ramp(sess):
    idle(sess, 0.5)
    job = next(j for j in sess.boards["HAR"] if j.weight_lb < 250)
    sess.accept_job(job)
    idle(sess, 3, held=["throttle_up"])  # still loading
    assert sess.state.gs_kts < 1
    idle(sess, 30)
    for it in list(sess.loadout.items.values()):
        sess.loadout.assignment.pop(it.id, None)
    idle(sess, 3, held=["throttle_up"])  # left on the ramp
    assert sess.state.gs_kts < 1


def test_takeoff_with_keyboard(sess):
    idle(sess, 0.5)
    for i in range(60 * 40):
        held = {"throttle_up"} if sess.mapper.controls.throttle < 1 else set()
        st = sess.state
        if st.ias_kts > 58 and st.pitch < 8:
            held.add("pitch_up")
        err = (st.heading - AIRFIELD_BY_CODE["HAR"].heading + 180) % 360 - 180
        if err > 1:
            held.add("yaw_left")
        elif err < -1:
            held.add("yaw_right")
        sess.update(1 / 60, InputFrame(held=held))
        assert sess.phase != "crashed", sess.last_outcome
        if sess.state.agl > 60:
            break
    assert sess.phase == "flying" and sess.location is None


def test_delivery_pays_on_arrival(sess):
    idle(sess, 0.5)
    job = sess.boards["HAR"][0]
    job.dest = "VAL"
    job.items = [it for it in job.items if it.kind == "cargo"][:1] or job.items[:1]
    assert sess.accept_job(job) is None
    idle(sess, 20)
    money = sess.money
    # teleport: rolling slowly down Valley's runway as if just landed
    sess.spawn_at("VAL")
    sess.log.airborne = True
    sess.phase = "flying"
    sess.location = None
    idle(sess, 6)
    assert sess.location == "VAL" and sess.parked
    assert sess.money > money
    assert not sess.active_jobs


def test_crash_into_ridge_then_respawn(sess):
    idle(sess, 0.3)
    sess.fm.spawn(0, 2500, 0, 0, sess.loadout, airborne_alt_m=450, speed_kts=100)
    sess.phase, sess.location, sess.log.airborne = "flying", None, True
    sess.log.departed_from = "VAL"
    sess.mapper.controls.throttle = 0.8
    for _ in range(60 * 90):
        sess.update(1 / 60, InputFrame())
        if sess.phase == "crashed":
            break
    assert sess.phase == "crashed"
    sess.update(1 / 60, InputFrame(pressed={"confirm"}))
    assert sess.phase == "parked" and sess.location == "VAL"
