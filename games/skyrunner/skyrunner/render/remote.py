"""Remote 3D seats: a co-pilot in the right seat, or a police pilot flying a
unit, on another machine.

The host runs the only simulation. This client renders the same procedural
world (built from the same seed, so nothing but entity state crosses the
wire) and draws aircraft, units and boats from role-filtered snapshots:

  * interpolated 100 ms behind the newest snapshot (snapshots arrive at
    20 Hz over TCP; rendering from a buffer hides jitter)
  * fog of war: the police pilot only gets another aircraft's position while
    their own unit can actually see it; radar tracks show as HUD markers
  * the co-pilot's crew keys (kick, pump, call boat, auto-kick) are ordinary
    commands; the police pilot's stick goes up as fire-and-forget input
"""
from __future__ import annotations

import sys
import time

from direct.gui.OnscreenText import OnscreenText
from direct.showbase.ShowBase import ShowBase
from panda3d.core import ClockObject, KeyboardButton, NodePath, TextNode, loadPrcFileData

from ..aircraft import ROSTER
from ..roles import Role
from ..world import World
from . import models
from .quality import get as quality_preset
from .scene import build_world_scene, graphics_prc

INTERP_DELAY_S = 0.10
LAW_KEYS = {"pitch_up": ("s", "arrow_down"), "pitch_down": ("w", "arrow_up"), "roll_left": ("a", "arrow_left"),
            "roll_right": ("d", "arrow_right"), "throttle_up": ("r",), "throttle_down": ("f",)}
CREW_KEYS = {"k": "kick", "o": "call_boat", "v": "pump", "t": "auto_kick"}


def _lerp_angle(a: float, b: float, t: float) -> float:
    d = (b - a + 180.0) % 360.0 - 180.0
    return a + d * t


class SnapshotBuffer:
    """Keeps recent snapshots with their arrival time; interpolates entity poses."""

    def __init__(self):
        self.items: list[tuple[float, dict]] = []

    def push(self, snap: dict) -> None:
        if snap is None or (self.items and self.items[-1][1].get("seq") == snap.get("seq")):
            return
        self.items.append((time.monotonic(), snap))
        del self.items[:-8]

    def pose(self, extract, now: float | None = None) -> dict | None:
        """extract(snap) -> dict with x, y, z, heading[, pitch, roll] or None."""
        if not self.items:
            return None
        t = (now or time.monotonic()) - INTERP_DELAY_S
        older = [(ts, s) for ts, s in self.items if ts <= t]
        newer = [(ts, s) for ts, s in self.items if ts > t]
        if not older:
            return extract(self.items[0][1])
        t0, s0 = older[-1]
        if not newer:
            return extract(s0)
        t1, s1 = newer[0]
        a, b = extract(s0), extract(s1)
        if a is None or b is None:
            return b or a
        f = (t - t0) / max(1e-6, t1 - t0)
        out = dict(b)
        for k in ("x", "y", "z"):
            out[k] = a[k] + (b[k] - a[k]) * f
        for k in ("heading", "pitch", "roll"):
            if k in a and k in b:
                out[k] = _lerp_angle(a[k], b[k], f)
        return out

    @property
    def latest(self) -> dict | None:
        return self.items[-1][1] if self.items else None


class RemoteSeatApp(ShowBase):
    def __init__(self, link, role: Role, graphics: str = "medium", offscreen: bool = False, world: World | None = None):
        self.quality = quality_preset(graphics)
        if offscreen and self.quality.shaders:
            self.quality = quality_preset("medium")
        loadPrcFileData("", graphics_prc(self.quality, offscreen, "Skyrunner seat"))
        super().__init__()
        self.link, self.role = link, Role(role)
        self.world = world or World()
        self.disableMouse()
        self.camLens.setNearFar(0.5, 60_000)
        self.camLens.setFov(75)
        self.scene = build_world_scene(self, self.world, self.quality)
        self.buf = SnapshotBuffer()
        self.nodes: dict[str, tuple[NodePath, list]] = {}
        self.cam_mode = "cockpit"
        self.look = [0.0, -5.0]  # head yaw, pitch
        self.throttle = 0.6
        self.hud = OnscreenText("", parent=self.a2dTopLeft, pos=(0.04, -0.07), scale=0.045, fg=(0.6, 1, 0.6, 1),
                                align=TextNode.ALeft, mayChange=True, shadow=(0, 0, 0, 0.8))
        self.msg = OnscreenText("", parent=self.a2dBottomLeft, pos=(0.04, 0.3), scale=0.04, fg=(1, 1, 1, 1),
                                align=TextNode.ALeft, mayChange=True, shadow=(0, 0, 0, 0.8))
        self.markers = OnscreenText("", parent=self.aspect2d, pos=(0, 0), scale=0.04, fg=(1, 0.4, 0.3, 1),
                                    mayChange=True)
        self.accept("c", self._cycle_cam)
        self.accept("escape", sys.exit)
        if self.role == Role.INTERCEPTOR:
            self.accept("space", self._send, ["claim_unit", {"kind": "interceptor"}])
            self.accept("h", self._send, ["claim_unit", {"kind": "heli"}])
            self.accept("x", self._send, ["release_unit", {}])
        else:
            for k, name in CREW_KEYS.items():
                self.accept(k, self._send, [name, {}])
        self._last_input = 0.0
        self.taskMgr.add(self._tick, "seat")

    # ------------------------------------------------------------ input
    def _send(self, name: str, args: dict) -> None:
        self.link.send_command(name, **args)

    def _cycle_cam(self) -> None:
        self.cam_mode = "chase" if self.cam_mode == "cockpit" else "cockpit"

    def _held(self) -> set[str]:
        mw = self.mouseWatcherNode
        out: set[str] = set()
        if mw is None:
            return out
        special = {"arrow_up": KeyboardButton.up(), "arrow_down": KeyboardButton.down(),
                   "arrow_left": KeyboardButton.left(), "arrow_right": KeyboardButton.right()}
        for action, keys in LAW_KEYS.items():
            if any(mw.isButtonDown(special.get(k) or KeyboardButton.asciiKey(k)) for k in keys):
                out.add(action)
        return out

    def _police_input(self, dt: float) -> None:
        h = self._held()
        roll = ("roll_right" in h) - ("roll_left" in h)
        pitch = ("pitch_up" in h) - ("pitch_down" in h)
        self.throttle = min(1.0, max(0.0, self.throttle + (("throttle_up" in h) - ("throttle_down" in h)) * 0.5 * dt))
        now = time.monotonic()
        if now - self._last_input > 1 / 30:
            self._last_input = now
            self.link.send_input(float(roll), float(pitch), self.throttle)

    def _crew_look(self, dt: float) -> None:
        h = self._held()
        self.look[0] += (("roll_left" in h) - ("roll_right" in h)) * 90 * dt
        self.look[1] = max(-60, min(40, self.look[1] + (("pitch_down" in h) - ("pitch_up" in h)) * 60 * dt))

    # ------------------------------------------------------------ entities
    def _node(self, key: str, factory) -> NodePath:
        if key not in self.nodes:
            node, extra = factory()
            node.reparentTo(self.render)
            self.nodes[key] = (node, extra)
        return self.nodes[key][0]

    def _place(self, node: NodePath, p: dict) -> None:
        node.setPos(p["x"], p["y"], p["z"])
        node.setHpr(-p["heading"], p.get("pitch", 0.0), p.get("roll", 0.0))

    def _sync(self, snap: dict) -> NodePath | None:
        seen: set[str] = set()
        me = None
        if self.role.side.value == "runner":
            ac = snap.get("aircraft")
            if ac:
                spec = ROSTER.get(ac.get("key", "c172p"), ROSTER["c172p"])
                gear = 1.2
                me = self._node(f"me:{spec.key}", lambda: models.build_aircraft(spec.visual, gear))
                p = self.buf.pose(lambda s: _runner_pose(s))
                if p:
                    self._place(me, p)
                seen.add(f"me:{spec.key}")
            for it in snap.get("intel", []):
                if it.get("source") == "visual" and "z" in it:
                    key = f"u:{it['unit']}"
                    n = self._node(key, lambda k=it.get("kind", "heli"): _pursuer(k))
                    p = self.buf.pose(lambda s, uid=it["unit"]: _intel_pose(s, uid))
                    if p:
                        self._place(n, p)
                    seen.add(key)
            for b in snap.get("boats", []):
                key = f"b:{b['id']}"
                n = self._node(key, lambda: models.build_boat("gofast"))
                n.setPos(b["x"], b["y"], 0.1)
                n.setHpr(-b["heading"], 0, 0)
                seen.add(key)
        else:
            m = snap.get("me")
            if m:
                me = self._node(f"me:{m['kind']}", lambda k=m["kind"]: _pursuer(k))
                p = self.buf.pose(lambda s: s.get("me"))
                if p:
                    self._place(me, p)
                seen.add(f"me:{m['kind']}")
            for v in snap.get("visual", []):
                key = f"v:{v['id']}"
                if v["kind"] in ("runner", "ai"):
                    spec = ROSTER.get(v.get("type", "c172p"), ROSTER["c172p"])
                    n = self._node(key, lambda sp=spec: models.build_aircraft(sp.visual, 1.2))
                else:
                    n = self._node(key, lambda k=v["kind"]: _pursuer(k))
                p = self.buf.pose(lambda s, vid=v["id"]: next((x for x in s.get("visual", []) if x["id"] == vid), None))
                if p:
                    self._place(n, p)
                seen.add(key)
        for key in list(self.nodes):
            if key not in seen:
                self.nodes.pop(key)[0].removeNode()
        return me

    # ------------------------------------------------------------ camera & HUD
    def _camera(self, me: NodePath | None, snap: dict) -> None:
        if me is None:
            self.camera.reparentTo(self.render)
            self.camera.setPos(0, -20000, 3000)
            self.camera.lookAt(0, 0, 0)
            return
        if self.cam_mode == "cockpit":
            me.hide()
            self.camera.reparentTo(me)
            side = 0.35 if self.role == Role.COPILOT else 0.0  # right seat
            self.camera.setPos(side, 1.2, 1.1)
            self.camera.setHpr(self.look[0], self.look[1], 0)
        else:
            me.show()
            self.camera.reparentTo(me)
            self.camera.setPos(0, -22, 6)
            self.camera.setHpr(0, -10, 0)

    def _hud(self, snap: dict) -> None:
        if self.role.side.value == "runner":
            ac = snap.get("aircraft") or {}
            lo = snap.get("loadout", {})
            wb = lo.get("wb", {})
            lines = [f"CO-PILOT  {ac.get('type', '')}  {ac.get('phase', '')}",
                     f"IAS {ac.get('ias', 0):.0f}  ALT {ac.get('alt', 0) / 0.3048:.0f} ft  HDG {ac.get('heading', 0):.0f}",
                     f"FUEL {ac.get('fuel', 0):.0f} + ferry {ac.get('ferry_fuel', 0):.0f} lb  pump {'ON' if ac.get('pumping') else 'off'}",
                     f"W&B {wb.get('weight', 0):.0f} lb  CG {wb.get('cg', 0):.1f}  {'OK' if wb.get('ok') else 'OUT'}",
                     f"XPDR {'on' if ac.get('transponder') else 'OFF'}  RADAR {ac.get('detector') or '-'}  WANTED {'*' * ac.get('wanted', 0)}",
                     f"kick queue {ac.get('kick_queue', 0)}  auto-kick {'on' if ac.get('auto_kick') else 'off'}",
                     "K kick  V pump  O call boat  T auto-kick  arrows look  C camera"]
            ss = snap.get("season")
            if ss:
                lines.append(f"NIGHT {ss['night']}/{ss['nights']}  heat {ss['public']['heat']}")
            self.hud.setText("\n".join(lines))
            self.msg.setText("\n".join(snap.get("messages", [])[-4:]))
        else:
            m = snap.get("me")
            if m:
                lines = [f"{m['id']} ({m['kind']})  {m['speed_kts']:.0f} kt  ALT {m['z'] / 0.3048:.0f} ft  AGL {m['agl'] / 0.3048:.0f}",
                         f"HDG {m['heading']:.0f}  bank {m['roll']:.0f}  throttle {self.throttle:.0%}  fuel {m['fuel_s'] / 60:.1f} min",
                         f"BUST {snap.get('bust_meter', 0):.0f}%   visual: " + (", ".join(f"{v['id']} {v['dist'] / 1000:.1f}km" for v in snap.get('visual', []) if v['kind'] in ('runner', 'ai')) or "none"),
                         "WASD fly  R/F throttle  X hand back to AI  C camera"]
            else:
                lines = ["POLICE PILOT - no aircraft", "SPACE launch an interceptor   H a helicopter"
                         + ("   (launching...)" if snap.get("claim_pending") else "")]
            tracks = [f"{t['id']} {t['source']} {t['age']:.0f}s" for t in snap.get("tracks", [])]
            lines.append("RADAR: " + (", ".join(tracks) if tracks else "no tracks"))
            self.hud.setText("\n".join(lines))
            self.msg.setText("\n".join(snap.get("messages", [])[-4:]))

    # ------------------------------------------------------------ loop
    def _tick(self, task):
        dt = min(ClockObject.getGlobalClock().getDt(), 0.1)
        self.link.tick(dt)
        snap = self.link.snapshot()
        if snap is None:
            self.hud.setText("Connecting...")
            return task.cont
        self.buf.push(snap)
        if self.role == Role.INTERCEPTOR:
            self._police_input(dt)
        else:
            self._crew_look(dt)
        me = self._sync(snap)
        self._camera(me, snap)
        self._hud(snap)
        self.scene.update(dt)
        return task.cont


def _runner_pose(s: dict) -> dict | None:
    ac = s.get("aircraft")
    if not ac:
        return None
    return {"x": ac["x"], "y": ac["y"], "z": ac["alt"], "heading": ac["heading"], "pitch": ac.get("pitch", 0.0),
            "roll": ac.get("roll", 0.0)}


def _intel_pose(s: dict, uid: str) -> dict | None:
    it = next((i for i in s.get("intel", []) if i["unit"] == uid and "z" in i), None)
    if it is None:
        return None
    return {"x": it["x"], "y": it["y"], "z": it["z"], "heading": it["heading"], "roll": it.get("bank", 0.0)}


def _pursuer(kind: str):
    node, spinners, lights = models.build_pursuer(kind if kind in ("heli", "interceptor", "rival") else "heli")
    return node, spinners


def main() -> None:
    import argparse

    from ..net.client import NetClient

    ap = argparse.ArgumentParser(description="Skyrunner 3D seat: co-pilot or police pilot on another machine")
    ap.add_argument("--connect", required=True, help="HOST:PORT of the host game")
    ap.add_argument("--role", default="copilot", choices=["copilot", "interceptor"])
    ap.add_argument("--name", default="player")
    ap.add_argument("--graphics", default="medium", choices=["low", "medium", "high"])
    args = ap.parse_args()
    host, _, port = args.connect.rpartition(":")
    link = NetClient(host or "127.0.0.1", int(port), args.name, args.role).start()
    RemoteSeatApp(link, Role(args.role), graphics=args.graphics).run()


if __name__ == "__main__":
    main()
