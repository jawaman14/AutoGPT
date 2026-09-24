import pytest

from skyrunner.aircraft import ROSTER
from skyrunner.fdm import FlightModel
from skyrunner.loadout import Item, Loadout, cg_limits_at, point_in_polygon


def test_envelope_helpers():
    env = ROSTER["c172p"].envelope
    assert point_in_polygon(42.0, 2000, env)
    assert not point_in_polygon(36.0, 2300, env)  # forward limit rises with weight
    fwd, aft = cg_limits_at(2400, env)
    assert fwd == pytest.approx(39.5) and aft == pytest.approx(47.3)


@pytest.mark.parametrize("key", list(ROSTER))
def test_prediction_matches_jsbsim(key, jsbsim_root, masses):
    """The load planner's numbers must agree with what JSBSim actually flies."""
    spec = ROSTER[key]
    lo = Loadout(spec, masses[key], fuel_lb=masses[key].fuel_capacity_lb * 0.4)
    for n, st in enumerate(i for i, s in enumerate(spec.stations) if s.kind != "pilot"):
        item = Item(n, "box", "cargo", 20 + 7 * n, job_id=1)
        lo.add(item)
        lo.assignment[item.id] = st
    fm = FlightModel(spec, jsbsim_root, masses[key])
    fm.spawn(0, 0, 0, 0, lo)
    s = fm.step(0.05, lambda x, y: 0.0)
    wb = lo.compute()
    assert s.weight_lb == pytest.approx(wb.weight_lb, abs=8)  # fuel burn during the step
    assert s.cg_in == pytest.approx(wb.cg_in, abs=0.2)


@pytest.mark.parametrize("key", list(ROSTER))
def test_default_empty_load_is_legal(key, masses):
    spec = ROSTER[key]
    lo = Loadout(spec, masses[key], fuel_lb=masses[key].fuel_capacity_lb * 0.5)
    assert lo.compute().ok, (key, lo.compute())


def test_auto_balance_fixes_a_tail_heavy_load(masses):
    spec = ROSTER["c172p"]
    lo = Loadout(spec, masses["c172p"], fuel_lb=150)
    items = [Item(1, "Crate", "cargo", 110, 1), Item(2, "Bag", "cargo", 45, 1), Item(3, "Pax", "passenger", 190, 1)]
    for it in items:
        lo.add(it)
    lo.assignment = {1: 4, 2: 5, 3: 2}  # everything aft
    assert not lo.compute().in_envelope
    assert lo.auto_balance()
    assert lo.compute().ok


def test_one_passenger_per_seat(masses):
    spec = ROSTER["c172p"]
    lo = Loadout(spec, masses["c172p"], fuel_lb=150)
    a, b = Item(1, "A", "passenger", 170, 1), Item(2, "B", "passenger", 170, 1)
    lo.add(a)
    lo.add(b)
    lo.assignment[a.id] = 1
    assert not lo.can_place(b, 1)
    assert not lo.can_place(b, 4)  # passengers don't ride in the baggage bay
    assert lo.can_place(b, 2)
