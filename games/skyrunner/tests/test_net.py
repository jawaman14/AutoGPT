"""Loopback multiplayer: host session + remote co-pilot and controller."""
import json
import time

import pytest

from skyrunner.game import Session
from skyrunner.net.client import LocalLink, NetClient
from skyrunner.net.server import HostServer
from skyrunner.net.snapshot import build_snapshot
from skyrunner.roles import Mode, Role


@pytest.fixture()
def host(world, jsbsim_root):
    sess = Session(world=world, jsbsim_root=jsbsim_root, seed=4, mode=Mode.VERSUS)
    srv = HostServer("127.0.0.1", 0, Mode.VERSUS).start()
    yield sess, srv
    srv.stop()


def pump_until(sess, srv, cond, secs=5.0):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        srv.pump(sess)
        sess.update(1 / 60)
        srv.publish(sess, force=True)
        if cond():
            return True
        time.sleep(0.005)
    return False


def test_copilot_joins_loads_and_gets_runner_snapshot(host):
    sess, srv = host
    cp = NetClient("127.0.0.1", srv.port, "Rosa", "copilot").start()
    assert pump_until(sess, srv, lambda: cp.latest is not None)
    assert sess.copilot == "human" and sess.loadout.copilot_aboard
    snap = cp.latest
    assert snap["side"] == "runner" and "loadout" in snap and "aircraft" in snap
    job = next(j for j in snap["board"] if j["weight"] < 250 and not j["airdrop"])
    seq = cp.send_command("accept_job", job_id=job["id"])
    assert pump_until(sess, srv, lambda: seq in cp.acks)
    assert cp.acks[seq][0], cp.acks[seq]
    assert any(j.id == job["id"] for j in sess.active_jobs)
    seq = cp.send_command("launch", kind="heli")  # not a runner command
    assert pump_until(sess, srv, lambda: seq in cp.acks)
    assert cp.acks[seq][0] is False
    cp.close()
    assert pump_until(sess, srv, lambda: sess.copilot is None)


def test_controller_sees_tracks_not_truth(host):
    sess, srv = host
    ctl = NetClient("127.0.0.1", srv.port, "Hart", "controller").start()
    assert pump_until(sess, srv, lambda: ctl.latest is not None)
    assert sess.police.controller == "human"
    snap = ctl.latest
    assert snap["side"] == "law"
    assert "aircraft" not in snap and "loadout" not in snap
    # the runner flies low over water, transponder off: no track, so the controller sees nothing
    sess.transponder = False
    sess.spawn_airborne(8000, -14000, 90, 30, 100)
    sess.mapper.controls.throttle = 0.8
    pump_until(sess, srv, lambda: False, secs=1.5)
    text = json.dumps(ctl.latest)
    assert "runner" not in [t["id"] for t in ctl.latest["tracks"]]
    assert f'{sess.state.x:.1f}' not in text
    seq = ctl.send_command("launch", kind="heli", base="HAR")
    assert pump_until(sess, srv, lambda: seq in ctl.acks)
    assert ctl.acks[seq][0]
    ctl.close()


def test_seat_rules(host):
    sess, srv = host
    with pytest.raises(ConnectionError):
        NetClient("127.0.0.1", srv.port, "X", "pilot").start()  # the host flies
    a = NetClient("127.0.0.1", srv.port, "A", "spotter").start()
    with pytest.raises(ConnectionError):
        NetClient("127.0.0.1", srv.port, "B", "spotter").start()
    a.close()


def test_local_link_police_mode(world, jsbsim_root):
    sess = Session(world=world, jsbsim_root=jsbsim_root, seed=9, mode=Mode.POLICE, humans={Role.CONTROLLER: "me"})
    link = LocalLink(sess, Role.CONTROLLER)
    for _ in range(30 * 25):
        link.tick(1 / 30)
    snap = link.snapshot()
    assert snap["side"] == "law" and snap["stock"]["heli"] == 1
    link.send_command("launch", kind="heli", base="VAL")
    assert link.last_result[0]
    assert json.dumps(build_snapshot(sess, Role.CONTROLLER))  # serialisable


def test_desk_sees_anonymous_track_numbers(world, jsbsim_root):
    sess = Session(world=world, jsbsim_root=jsbsim_root, seed=4, mode=Mode.VERSUS)
    sess.transponder = False
    sess.spawn_airborne(-4000, -8000, 45, 400, 100)
    sess.mapper.controls.throttle = 0.75
    sess.command(Role.PILOT, "autopilot", on=True)
    for _ in range(60 * 5):
        sess.update(1 / 60)
    snap = build_snapshot(sess, Role.CONTROLLER)
    ids = [t["id"] for t in snap["tracks"]]
    assert ids and all(i.startswith("T") for i in ids)
    assert "\"runner\"" not in json.dumps(snap)  # the internal id never appears as a value
    # the desk can dispatch against the alias
    sess.police.launch("heli", "HAR")
    for _ in range(60 * 8):
        sess.update(1 / 60)
    hawk = sess.police.units[0]
    ok, _ = sess.command(Role.CONTROLLER, "dispatch", unit=hawk.id, target=ids[0])
    assert ok and hawk.target_id == "runner"
