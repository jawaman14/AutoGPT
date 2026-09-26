"""The game's core promise: weight and balance change how the aircraft flies."""
from skyrunner.aircraft import ROSTER
from skyrunner.fdm import FlightModel
from skyrunner.loadout import Item, Loadout

FLAT = lambda x, y: 0.0  # noqa: E731


def _load(masses, stations_weights, fuel=200):
    spec = ROSTER["c172p"]
    lo = Loadout(spec, masses["c172p"], fuel_lb=fuel)
    for n, (st, w) in enumerate(stations_weights):
        lo.add(Item(n, "x", "cargo", w, 0))
        lo.assignment[n] = st
    return lo


def _takeoff_distance(lo, root, masses):
    fm = FlightModel(lo.spec, root, masses["c172p"])
    fm.spawn(0, 0, 0, 0, lo)
    fm.controls.throttle = 1.0
    for _ in range(60 * 60):
        s = fm.state()
        err = (s.heading + 180) % 360 - 180
        fm.controls.rudder = max(-1.0, min(1.0, -err * 0.1))
        fm.controls.elevator = -0.3 if s.ias_kts > 55 and s.pitch < 8 else 0.0
        s = fm.step(1 / 60, FLAT)
        if not s.on_ground and s.agl > masses["c172p"].gear_height_ft * 0.3048 + 0.5:
            return s.y
    raise AssertionError("never lifted off")


def test_heavy_needs_more_runway(jsbsim_root, masses):
    light = _takeoff_distance(_load(masses, []), jsbsim_root, masses)
    heavy = _takeoff_distance(_load(masses, [(1, 200), (2, 170), (3, 170), (4, 100)]), jsbsim_root, masses)
    assert heavy > light * 1.4, (light, heavy)


def test_aft_cg_pitches_up(jsbsim_root, masses):
    def pitch_after(lo):
        fm = FlightModel(lo.spec, jsbsim_root, masses["c172p"])
        fm.spawn(0, 0, 0, 0, lo, airborne_alt_m=1000, speed_kts=90)
        fm.controls.throttle = 0.7
        for _ in range(180):
            s = fm.step(1 / 60, FLAT)
        return s.pitch

    fwd = _load(masses, [(1, 250)])
    aft = _load(masses, [(4, 120), (5, 50), (2, 150)])
    assert fwd.compute().in_envelope and not aft.compute().in_envelope
    assert pitch_after(aft) > pitch_after(fwd) + 6


def test_pedals_steer_the_right_way(jsbsim_root, masses):
    for key in ROSTER:
        spec = ROSTER[key]
        fm = FlightModel(spec, jsbsim_root, masses[key])
        fm.spawn(0, 0, 0, 0, Loadout(spec, masses[key], 200))
        fm.controls.throttle = 0.45
        for i in range(60 * 8):
            fm.controls.rudder = 1.0 if i > 60 else 0.0
            s = fm.step(1 / 60, FLAT)
        assert 20 < s.heading < 300, (key, s.heading)  # turned right, not left


def test_terrain_strike_is_a_crash(jsbsim_root, masses):
    spec = ROSTER["c172p"]
    fm = FlightModel(spec, jsbsim_root, masses["c172p"])
    fm.spawn(0, 0, 0, 0, Loadout(spec, masses["c172p"], 200), airborne_alt_m=100, speed_kts=90)
    wall = lambda x, y: 150.0 if y > 200 else 0.0  # noqa: E731
    for _ in range(60 * 10):
        fm.step(1 / 60, wall)
        if fm.crash_reason:
            break
    assert fm.crash_reason == "Flew into terrain"
