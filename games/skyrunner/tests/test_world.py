import math

import pytest

from skyrunner.world import AIRFIELDS


@pytest.mark.parametrize("af", AIRFIELDS, ids=lambda a: a.code)
def test_runways_are_flat_dry_and_clear(world, af):
    elev = world.airfield_elev(af)
    assert elev > 0
    for along in (-0.5, -0.25, 0, 0.25, 0.5):
        for across in (-0.5, 0, 0.5):
            ux, uy = af.dir
            x = af.x + ux * along * af.length + uy * across * af.width
            y = af.y + uy * along * af.length - ux * across * af.width
            assert world.ground(x, y) == pytest.approx(elev)
            assert not world.tree_hit(x, y, elev + 2)


@pytest.mark.parametrize("af", AIRFIELDS, ids=lambda a: a.code)
def test_every_strip_has_an_open_approach(world, af):
    """At least one end must be landable: a 4 deg path from 1.5 km out clears terrain."""
    elev = world.airfield_elev(af)
    ok = []
    for end in (0, 1):
        tx, ty = af.threshold(end)
        ux, uy = af.dir
        s = -1 if end == 0 else 1
        clear = all(
            world.ground(tx + s * ux * d, ty + s * uy * d) < elev + d * math.tan(math.radians(4)) - 5
            for d in range(150, 1500, 50)
        )
        ok.append(clear)
    assert any(ok), af.code


def test_special_strips(world):
    by = {a.code: a for a in AIRFIELDS}
    egl = by["EGL"]  # plateau: cliff edges
    assert world.height(egl.x + egl.dir[1] * 300, egl.y - egl.dir[0] * 300) < world.airfield_elev(egl) - 200
    qry = by["QRY"]  # trench: walls beside the strip
    assert world.height(qry.x + qry.dir[1] * 50, qry.y - qry.dir[0] * 50) > world.airfield_elev(qry) + 30
    pnr = by["PNR"]  # one-way: terrain rises steeply past the far end
    fx, fy = pnr.threshold(1)
    assert world.ground(fx + pnr.dir[0] * 600, fy + pnr.dir[1] * 600) > world.airfield_elev(pnr) + 200


def test_line_of_sight_blocked_by_ridge(world):
    assert world.line_of_sight((0, -3000, 1500), (0, 12000, 1500))
    assert not world.line_of_sight((0, -3000, 200), (0, 12000, 200))
