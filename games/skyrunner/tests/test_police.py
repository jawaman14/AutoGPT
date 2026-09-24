import random

from skyrunner.comms import Bearing, RadioNet, intersect
from skyrunner.police import PoliceSystem, Pursuer, Target
from skyrunner.sensors import SensorNet, Signature
from skyrunner.world import AIRFIELD_BY_CODE


def _sig(world, x, y, agl, tid="runner", transponder=False, vx=0.0, vy=50.0):
    g = world.ground(x, y)
    return Signature(tid, x, y, g + agl, agl, vx, vy, "air", transponder, "N123A" if transponder else "")


def _run(ps, targets, secs, dt=0.05, t0=0.0):
    out = {}
    t = t0
    for _ in range(int(secs / dt)):
        t += dt
        out.update(ps.tick(dt, t, targets))
    return out, t


def test_radar_sees_high_not_low(world):
    net = SensorNet(world, random.Random(1))
    har = AIRFIELD_BY_CODE["HAR"]
    x, y = har.x + 2000, har.y - 4000  # over open water
    high = net.sweep([_sig(world, x, y, 600)], 1.0)["runner"]
    low = net.sweep([_sig(world, x, y, 40)], 2.0)["runner"]
    assert high.detected_by and high.detector_level == "LOCK"
    assert not low.detected_by and low.detector_level == "PAINT"  # detector warns, radar can't hold you


def test_transponder_is_seen_below_the_floor(world):
    net = SensorNet(world, random.Random(1))
    har = AIRFIELD_BY_CODE["HAR"]
    det = net.sweep([_sig(world, har.x + 2000, har.y - 4000, 20, transponder=True)], 1.0)["runner"]
    assert det.detected_by
    assert net.tracks["runner"].squawk == "N123A"


def test_aerostat_sees_low_targets(world):
    net = SensorNet(world, random.Random(1))  # aerostat starts winched down
    sig = _sig(world, 0, -9000, 80)
    assert not net.sweep([sig], 1.0)["runner"].detected_by
    net.site("AER").active = True
    assert net.sweep([sig], 2.0)["runner"].detected_by == ["AER"]


def test_unidentified_primary_track_builds_suspicion_and_dispatch(world):
    ps = PoliceSystem(world, random.Random(1))
    har = AIRFIELD_BY_CODE["HAR"]
    sig = _sig(world, har.x + 5000, har.y + 3000, 800)
    _run(ps, [Target(sig, hot=True)], 30)
    assert ps.wanted >= 1
    assert any(u.faction == "police" for u in ps.units)


def test_squawking_traffic_is_ignored_unless_tipped(world):
    har = AIRFIELD_BY_CODE["HAR"]
    sig = _sig(world, har.x + 5000, har.y + 3000, 800, transponder=True)
    ps = PoliceSystem(world, random.Random(1))
    _run(ps, [Target(sig, hot=True)], 30)
    assert ps.wanted == 0 and ps.suspicion == 0
    ps2 = PoliceSystem(world, random.Random(1), features={"informants"})
    ps2.add_tip(sig.x, sig.y, 3000, "tip", squawk="N123A", target_id="runner")
    _run(ps2, [Target(sig, hot=True)], 30)
    assert ps2.suspicion > 40 or ps2.wanted


def test_squawk_lost_is_a_red_flag(world):
    ps = PoliceSystem(world, random.Random(1))
    har = AIRFIELD_BY_CODE["HAR"]
    on = _sig(world, har.x + 5000, har.y + 3000, 800, transponder=True)
    _, t = _run(ps, [Target(on)], 5)
    off = _sig(world, har.x + 5000, har.y + 3000, 800, transponder=False)
    _run(ps, [Target(off)], 1.5, t0=t)
    assert ps.suspicion >= 50


def test_units_chase_last_known_not_truth(world):
    ps = PoliceSystem(world, random.Random(1))
    ps.case("runner").wanted = 3
    ps.case("runner").last_known = (0.0, -6000.0, 0.0)
    u = Pursuer("heli", 0, -8000, 400, 0.0, (0, -9000), speed=50, id="Hawk-1", target_id="runner")
    ps.units.append(u)
    hidden = _sig(world, 8000, 8000, 30)  # far away, low, behind the ridge
    _run(ps, [Target(hidden, hot=True)], 45)
    assert u.target_id == "runner"
    assert ((u.x) ** 2 + (u.y + 6000) ** 2) ** 0.5 < 900  # orbiting where it was last seen


def test_pursuer_closes_and_busts(world):
    ps = PoliceSystem(world, random.Random(1))
    ps.case("runner").wanted = 1
    ps.units.append(Pursuer("interceptor", 0, -9000, 900, 0.0, (0, -9000), speed=80, id="Falcon-1", target_id="runner"))
    x, y, out, t = 0.0, -6000.0, {}, 0.0
    for _ in range(4000):
        y += 40 * 0.05
        t += 0.05
        sig = Signature("runner", x, y, 900, 900 - world.ground(x, y), 0.0, 40.0)
        out = ps.tick(0.05, t, [Target(sig, hot=True)])
        if out:
            break
    assert out == {"runner": "busted"}


def test_clean_aircraft_is_released(world):
    ps = PoliceSystem(world, random.Random(1))
    ps.case("runner").wanted = 1
    ps.units.append(Pursuer("interceptor", 0, -6600, 900, 0.0, (0, -9000), speed=60, id="Falcon-1", target_id="runner"))
    t, out = 0.0, {}
    for _ in range(2000):
        t += 0.05
        sig = Signature("runner", 0, -6000 + t * 40, 900, 500, 0.0, 40.0)
        out = ps.tick(0.05, t, [Target(sig, hot=False)])
        if out:
            break
    assert out == {"runner": "clean"}


def test_pursuer_can_fly_into_terrain(world):
    """Terrain avoidance only looks straight ahead - a steep enough wall wins."""
    u = Pursuer("interceptor", 0, 1500, 350, 0.0, (0, 0), speed=110)
    target = Signature("x", 0, 12000, 350, 0)
    for _ in range(2000):
        u.update(0.05, target, world)
        if u.state == "crashed":
            break
    ridge_top = max(world.ground(0, y) for y in range(1500, 12000, 100))
    assert u.state == "crashed" or u.z > ridge_top


def test_encryption_hides_dispatch_from_scanner():
    radio = RadioNet(random.Random(1))
    radio.transmit(1.0, "police", "Hawk-1", "airborne from Harbor", (0, 0))
    radio.encrypted = True
    radio.transmit(2.0, "police", "Hawk-1", "tally on target", (0, 0))
    heard = [text for _, text in radio.scanner(0.0)]
    assert "Hawk-1: airborne from Harbor" in heard
    assert any("scrambled" in h for h in heard)


def test_direction_finding_fix():
    radio = RadioNet(random.Random(2), df_enabled=True, df_stations=[("A", -9000, -9500), ("B", 2500, -3000)])
    msg = radio.transmit(1.0, "runner", "N1", "boat, come to me", (8000, -12000))
    res = radio.direction_find(msg)
    assert len(res.bearings) == 2 and res.fix is not None
    # ~2.5 deg bearing error at 15+ km: the fix is a search area, not a point
    assert abs(res.fix[0] - 8000) < 3000 and abs(res.fix[1] + 12000) < 3000


def test_intersect_parallel_is_none():
    assert intersect(Bearing("a", 0, 0, 90), Bearing("b", 0, 100, 90)) is None
