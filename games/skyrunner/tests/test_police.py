import random

from skyrunner.fdm import FlightState
from skyrunner.police import PoliceSystem, Pursuer
from skyrunner.world import AIRFIELD_BY_CODE


def _state(x, y, alt, vx=0.0, vy=50.0):
    return FlightState(x=x, y=y, alt=alt, agl=0, heading=0, pitch=0, roll=0, ias_kts=100, gs_kts=100,
                       vs_fpm=0, alpha_deg=2, on_ground=False, wow_count=0, fuel_lb=100, weight_lb=2000,
                       cg_in=42, rpm=2400, engine_running=True, stall_warning=False, valid=True, vx=vx, vy=vy)


def test_radar_sees_high_not_low(world):
    ps = PoliceSystem(world, random.Random(1))
    har = AIRFIELD_BY_CODE["HAR"]
    x, y = har.x + 8000, har.y + 2000
    g = world.ground(x, y)
    assert ps.radar_detects(_state(x, y, g + 600)) is not None
    assert ps.radar_detects(_state(x, y, g + 40)) is None


def test_suspicion_leads_to_dispatch(world):
    ps = PoliceSystem(world, random.Random(1))
    har = AIRFIELD_BY_CODE["HAR"]
    s = _state(har.x + 5000, har.y + 3000, world.ground(har.x + 5000, har.y + 3000) + 800)
    for _ in range(600):
        ps.update(0.05, s, carrying_hot=True, hot_value=500)
    assert ps.wanted >= 1
    assert any(u.faction == "police" for u in ps.units)


def test_clean_aircraft_is_ignored(world):
    ps = PoliceSystem(world, random.Random(1))
    har = AIRFIELD_BY_CODE["HAR"]
    s = _state(har.x + 5000, har.y + 3000, 1000)
    for _ in range(600):
        ps.update(0.05, s, carrying_hot=False, hot_value=0)
    assert ps.wanted == 0 and not ps.units


def test_pursuer_closes_and_busts(world):
    ps = PoliceSystem(world, random.Random(1))
    ps.wanted = 1
    s = _state(0, -6000, 900, vx=0, vy=40)
    ps.units.append(Pursuer("interceptor", 0, -9000, 900, 0.0, (0, -9000), speed=80))
    outcome = None
    for _ in range(4000):
        s = _state(s.x, s.y + 40 * 0.05, 900, vy=40)
        outcome = ps.update(0.05, s, carrying_hot=True, hot_value=500)
        if outcome:
            break
    assert outcome == "busted"


def test_pursuer_can_fly_into_terrain(world):
    """Terrain avoidance only looks straight ahead - a steep enough wall wins."""
    u = Pursuer("interceptor", 0, 1500, 350, 0.0, (0, 0), speed=110)
    for _ in range(2000):
        u.update(0.05, _state(0, 12000, 350), world)
        if u.state == "crashed":
            break
    ridge_top = max(world.ground(0, y) for y in range(1500, 12000, 100))
    assert u.state == "crashed" or u.z > ridge_top
