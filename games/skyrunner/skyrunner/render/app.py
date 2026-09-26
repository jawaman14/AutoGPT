"""Panda3D front-end: scene graph, cameras, input, HUD, menus."""
from __future__ import annotations

import math
import sys

from direct.gui.OnscreenText import OnscreenText
from direct.showbase.ShowBase import ShowBase
from panda3d.core import (
    InputDevice,
    ClockObject,
    KeyboardButton,
    TextNode,
    Vec3,
    WindowProperties,
    loadPrcFileData,
)

from ..controls import InputFrame
from ..game import Session
from ..roles import Role
from ..sensors import AEROSTAT_POS
from ..world import AIRFIELD_BY_CODE
from . import models
from .hud import HELP_TEXT, HangarMenu, Hud, JobMenu, LoadMenu
from .quality import get as quality_preset
from .scene import build_world_scene, graphics_prc

SKY = (0.55, 0.72, 0.9, 1)
CAM_MODES = ("chase", "cockpit", "tower")

HELD_KEYS = {
    "pitch_up": ("s", "arrow_down"),
    "pitch_down": ("w", "arrow_up"),
    "roll_left": ("a", "arrow_left"),
    "roll_right": ("d", "arrow_right"),
    "yaw_left": ("q",),
    "yaw_right": ("e",),
    "throttle_up": ("r", "page_up"),
    "throttle_down": ("f", "page_down"),
    "brake": ("b", "space"),
    "trim_up": ("]",),
    "trim_down": ("[",),
}
CREW_KEYS = {  # one-shot crew commands issued from the pilot's seat
    "n": ("transponder", {}),
    "u": ("autopilot", {}),
    "k": ("kick", {}),
    "o": ("call_boat", {}),
    "v": ("pump", {}),
    "i": ("turn_around", {}),
}
PRESS_KEYS = {
    "g": "flaps_down",
    "t": "flaps_up",
    "x": "throttle_cut",
    "z": "throttle_full",
    "enter": "confirm",
}


def _button(name: str):
    special = {
        "arrow_up": KeyboardButton.up(),
        "arrow_down": KeyboardButton.down(),
        "arrow_left": KeyboardButton.left(),
        "arrow_right": KeyboardButton.right(),
        "page_up": KeyboardButton.pageUp(),
        "page_down": KeyboardButton.pageDown(),
        "space": KeyboardButton.space(),
    }
    return special.get(name) or KeyboardButton.asciiKey(name)


class SkyrunnerApp(ShowBase):
    def __init__(self, session: Session, offscreen: bool = False, server=None, graphics: str = "high", bot=None):
        self.quality = quality_preset(graphics)
        if offscreen and self.quality.shaders:  # software rendering: no shader generator
            self.quality = quality_preset("medium" if self.quality.textures else "low")
        loadPrcFileData("", graphics_prc(self.quality, offscreen))
        super().__init__()
        self.s = session
        self.server = server
        self.bot = bot  # bots.autorun.AutoRunner: the AI flies, you watch
        self.disableMouse()
        self.camLens.setNearFar(0.5, 60_000)
        self.camLens.setFov(70)

        self._build_scene()
        self.hud = Hud(self, session)
        self.menus = {"j": JobMenu(self, session), "l": LoadMenu(self, session), "h": HangarMenu(self, session)}
        self.help = OnscreenText(HELP_TEXT, parent=self.aspect2d, pos=(-1.2, 0.7), scale=0.045,
                                 fg=(1, 1, 1, 1), bg=(0, 0, 0, 0.8), align=TextNode.ALeft, mayChange=False)
        self.help.hide()
        self.glareshield = self._build_glareshield()
        self.briefing = OnscreenText("", parent=self.aspect2d, pos=(-1.2, 0.55), scale=0.05, fg=(1, 0.85, 0.5, 1),
                                     bg=(0, 0, 0, 0.85), align=TextNode.ALeft, mayChange=True)
        self.briefing.hide()

        self.cam_mode = "chase"
        self.mouse_yoke = False
        self.paused = False
        self._pressed: set[str] = set()
        self._cam_pos = None
        self._bind_keys()
        self._stick = None
        if not offscreen:
            self._attach_stick()
            self.accept("connect-device", lambda d: self._attach_stick())
            self.accept("disconnect-device", lambda d: self._attach_stick())
        self.taskMgr.add(self._tick, "tick")

    # ------------------------------------------------------------ scene
    def _build_scene(self):
        self.scene = build_world_scene(self, self.s.world, self.quality)
        self.beacons = []
        self._build_player()
        self.pursuer_nodes: dict[int, tuple] = {}
        self.boat_nodes: dict[str, tuple] = {}
        self.bale_nodes: dict[int, object] = {}
        self.aerostat = models.build_aerostat()
        self.aerostat.reparentTo(self.render)
        self.aerostat.setPos(AEROSTAT_POS[0], AEROSTAT_POS[1], 2500)
        self.aerostat.hide()

    def _build_player(self):
        if getattr(self, "player", None) is not None:
            self.player.removeNode()
        spec = self.s.spec
        self.player, self.props = models.build_aircraft(spec.visual, self.s.fm.mass.gear_height_ft * 0.3048)
        self.player.reparentTo(self.render)
        self._player_key = spec.key
        if self.quality.shadows:
            self.scene.sun.reparentTo(self.player)  # the shadow camera follows us
            self.scene.sun.setHpr(self.render, -35, -50, 0)

    def _sync_beacons(self):
        want = sorted({(j.dest, j.drop_point) for j in self.s.active_jobs}, key=str)
        if want == [b[0] for b in self.beacons]:
            return
        for _, nodes in self.beacons:
            for n in nodes:
                n.removeNode()
        self.beacons = []
        for key in want:
            code, drop = key
            nodes = []
            if drop is not None:  # rendezvous at sea: one tall blue marker
                b = models.build_beacon(height=400, radius=10, color=(0.3, 0.6, 1.0, 0.35))
                b.reparentTo(self.render)
                b.setPos(drop[0], drop[1], 0)
                nodes.append(b)
            else:
                af = AIRFIELD_BY_CODE[code]
                for end in (0, 1):
                    x, y = af.threshold(end)
                    b = models.build_beacon()
                    b.reparentTo(self.render)
                    b.setPos(x, y, self.s.world.airfield_elev(af))
                    nodes.append(b)
            self.beacons.append((key, nodes))

    def _build_glareshield(self):
        """Cockpit view: a dark glareshield along the bottom and a waterline marker
        showing where the nose points (the 3D airframe is hidden in this view)."""
        from direct.gui.DirectGui import DirectFrame
        from panda3d.core import LineSegs

        root = self.aspect2d.attachNewNode("glareshield")
        DirectFrame(parent=root, frameColor=(0.08, 0.08, 0.09, 1), frameSize=(-3, 3, -1, -0.62))
        ls = LineSegs()
        ls.setThickness(3)
        ls.setColor(1, 0.8, 0.2, 1)
        for seg in (((-0.12, 0), (-0.05, 0)), ((-0.05, 0), (-0.025, -0.03)), ((-0.025, -0.03), (0, 0)),
                    ((0, 0), (0.025, -0.03)), ((0.025, -0.03), (0.05, 0)), ((0.05, 0), (0.12, 0))):
            ls.moveTo(seg[0][0], 0, seg[0][1])
            ls.drawTo(seg[1][0], 0, seg[1][1])
        root.attachNewNode(ls.create())
        root.setBin("background", 10)  # draw under the HUD text, minimap and PAPI
        root.hide()
        return root

    # ------------------------------------------------------------ input
    def _bind_keys(self):
        for key, action in PRESS_KEYS.items():
            self.accept(key, self._pressed.add, [action])
        for key, (name, args) in CREW_KEYS.items():
            self.accept(key, self._crew, [name, args])
        for k in ("j", "l", "h"):
            self.accept(k, self._toggle_menu, [k])
        self.accept("escape", self._escape)
        self.accept("c", self._cycle_cam)
        self.accept("m", lambda: self.hud.minimap.toggle())
        self.accept("y", self._toggle_yoke)
        self.accept("p", self._toggle_pause)
        self.accept("f1", lambda: self.help.hide() if not self.help.isHidden() else self.help.show())
        for k, name in (("arrow_up", "up"), ("arrow_down", "down"), ("arrow_left", "left"),
                        ("arrow_right", "right"), ("enter", "enter"), ("a", "a"), ("+", "+"),
                        ("=", "+"), ("-", "-"), ("f", "f")):
            self.accept(k, self._menu_key, [name])
            self.accept(k + "-repeat", self._menu_key, [name]) if k.startswith("arrow") else None

    def _crew(self, name: str, args: dict):
        if self._active_menu() is not None:
            return
        ok, msg = self.s.command(Role.PILOT, name, **args)
        if not ok:
            self.s.say(msg)

    def _active_menu(self):
        return next((m for m in self.menus.values() if m.visible), None)

    def _toggle_menu(self, k):
        m = self.menus[k]
        if m.visible:
            m.hide()
            return
        if not self.s.parked:
            self.s.say("Come to a full stop at an airfield first.")
            return
        for other in self.menus.values():
            other.hide()
        m.show()

    def _menu_key(self, name):
        m = self._active_menu()
        if m:
            m.key(name)

    def _escape(self):
        m = self._active_menu()
        if m:
            m.hide()
        elif not self.help.isHidden():
            self.help.hide()
        else:
            self.s.save()
            sys.exit(0)

    def _cycle_cam(self):
        self.cam_mode = CAM_MODES[(CAM_MODES.index(self.cam_mode) + 1) % len(CAM_MODES)]
        self._cam_pos = None

    def _toggle_yoke(self):
        self.mouse_yoke = not self.mouse_yoke
        self.s.say(f"Mouse yoke {'ON - mouse position is the stick' if self.mouse_yoke else 'OFF'}")

    def _toggle_pause(self):
        self.paused = not self.paused

    def _gather_input(self) -> InputFrame:
        inp = InputFrame(pressed=self._pressed)
        self._pressed = set()
        menu_open = self._active_menu() is not None
        mw = self.mouseWatcherNode
        if mw is None:  # offscreen buffer: no keyboard
            return inp
        if not menu_open:
            for action, keys in HELD_KEYS.items():
                if any(mw.isButtonDown(_button(k)) for k in keys):
                    inp.held.add(action)
        else:
            inp.pressed.discard("confirm")
        if self.mouse_yoke and mw.hasMouse() and not menu_open:
            m = mw.getMouse()
            dz = lambda v: 0.0 if abs(v) < 0.04 else v  # noqa: E731
            inp.stick = (max(-1, min(1, dz(m.x) * 1.3)), max(-1, min(1, -dz(m.y) * 1.3)))
        if not menu_open:
            self._poll_stick(inp)
        return inp

    def _attach_stick(self):
        """Use the first flight stick or gamepad, if any. Keyboard still works."""
        if self._stick is not None:
            self.detachInputDevice(self._stick)
            self._stick = None
        C = InputDevice.DeviceClass
        for cls in (C.flight_stick, C.gamepad):
            devs = self.devices.getDevices(cls)
            if devs:
                self._stick = devs[0]
                self.attachInputDevice(self._stick)
                self.s.say(f"Controller: {self._stick.name}")
                return

    def _poll_stick(self, inp: InputFrame):
        dev = self._stick
        if dev is None or not dev.connected:
            return
        A = InputDevice.Axis

        def ax(*names):
            for n in names:
                a = dev.findAxis(n)
                if a is not None:
                    return a.value
            return None

        dz = lambda v: 0.0 if v is None or abs(v) < 0.06 else v  # noqa: E731
        roll = ax(A.roll, A.x, A.left_x)
        pitch = ax(A.pitch, A.y, A.left_y)
        if roll is not None and pitch is not None:
            # Panda reports +y for stick forward; our stick +1 = pull back
            inp.stick = (dz(roll), -dz(pitch))
        rud = ax(A.yaw, A.rudder, A.right_x)
        if rud is not None:
            inp.rudder_axis = dz(rud)
        thr = ax(A.throttle)
        if thr is not None:
            inp.throttle_axis = max(0.0, min(1.0, thr))
        else:
            lt, rt = ax(A.left_trigger), ax(A.right_trigger)
            if rt and rt > 0.3:
                inp.held.add("throttle_up")
            if lt and lt > 0.3:
                inp.held.add("throttle_down")

    # ------------------------------------------------------------ loop
    def _tick(self, task):
        dt = min(ClockObject.getGlobalClock().getDt(), 0.1)
        camp = self.s.campaign
        if camp is not None and camp.show_briefing:
            ch = camp.chapter
            self.briefing.setText(f"CHAPTER {ch.num}  -  {ch.year}  -  {ch.title}\n\n{ch.briefing}\n\n"
                                  + "\n".join(camp.objective_lines()) + "\n\nPress ENTER")
            self.briefing.show()
            if "confirm" in self._pressed:
                camp.show_briefing = False
                self._pressed.discard("confirm")
                self.briefing.hide()
            self._pressed.clear()
        elif not self.paused:
            if self._player_key != self.s.aircraft_key:
                self._build_player()
            if self.server is not None:
                self.server.pump(self.s)
            inp = self._gather_input()
            self.s.update(dt, inp, controls=self.bot.step(dt) if self.bot else None)
            if self.server is not None:
                self.server.publish(self.s)
        self._sync_scene(dt)
        self.scene.update(dt)
        self.hud.update(self.cam_mode, self.mouse_yoke)
        m = self._active_menu()
        self.hud.flight.show() if m is None else self.hud.flight.hide()
        if m:
            if not self.s.parked:
                m.hide()
            elif int(task.frame) % 10 == 0:
                m.refresh()
        return task.cont

    def _sync_scene(self, dt):
        st = self.s.state
        if st is None:
            return
        self.player.setPos(st.x, st.y, st.alt)
        self.player.setHpr(-st.heading, st.pitch, st.roll)
        spin = 360 * 2400 / 60 * dt * max(0.15, self.s.fm.controls.throttle if st.engine_running else 0)
        for p in self.props:
            p.setR(p.getR() + spin)
        self._sync_beacons()
        self._sync_pursuers(dt)
        self._sync_maritime(dt)
        aer = self.s.police.sensors.site("AER")
        self.aerostat.show() if aer and aer.active else self.aerostat.hide()
        self._update_camera(st, dt)

    def _sync_maritime(self, dt):
        mar = self.s.maritime
        live = {b.id: b for b in mar.boats if b.state not in ("delivered",)}
        for bid in list(self.boat_nodes):
            if bid not in live:
                self.boat_nodes.pop(bid)[0].removeNode()
        blink = int(self.s.time * 3) % 2
        for bid, b in live.items():
            if bid not in self.boat_nodes:
                node, lights = models.build_boat(b.kind)
                node.reparentTo(self.render)
                self.boat_nodes[bid] = (node, lights)
            node, lights = self.boat_nodes[bid]
            bob = math.sin(self.s.time * 2 + hash(bid) % 7) * 0.15
            node.setPos(b.x, b.y, bob)
            node.setHpr(-b.heading, min(8.0, b.speed * 0.25), 0)
            for ln in lights:
                ln.setColorScale((1, 1, 1, 1) if blink else (0.2, 0.2, 0.2, 1))
            if b.state == "seized":
                node.setColorScale(0.5, 0.5, 0.5, 1)
        live_bales = {bl.id: bl for bl in mar.bales if bl.state in ("falling", "floating", "landed")}
        for blid in list(self.bale_nodes):
            if blid not in live_bales:
                self.bale_nodes.pop(blid).removeNode()
        for blid, bl in live_bales.items():
            if blid not in self.bale_nodes:
                n = models.build_bale()
                n.reparentTo(self.render)
                self.bale_nodes[blid] = n
            self.bale_nodes[blid].setPos(bl.x, bl.y, bl.z)
        # AI runs (police-vs-AI games watched from the pilot client, or versus later)
        for a in self.s.smugglers:
            key = f"ai:{a.id}"
            if key not in self.boat_nodes and a.active:
                node, spinners = models.build_aircraft(models.Visual("low", 2, 11.0, 12.5, (0.07, 0.07, 0.07), (0.6, 0.1, 0.6)), 1.2)
                node.reparentTo(self.render)
                self.boat_nodes[key] = (node, [])
            if key in self.boat_nodes:
                self.boat_nodes[key][0].setPos(a.x, a.y, a.z)
                self.boat_nodes[key][0].setHpr(-a.heading, 0, 0)

    def _sync_pursuers(self, dt):
        live = {id(u): u for u in self.s.police.units}
        for uid in list(self.pursuer_nodes):
            if uid not in live:
                self.pursuer_nodes.pop(uid)[0].removeNode()
        blink = int(self.s.time * 4) % 2
        for uid, u in live.items():
            if uid not in self.pursuer_nodes:
                node, spinners, lights = models.build_pursuer(u.kind)
                node.reparentTo(self.render)
                self.pursuer_nodes[uid] = (node, spinners, lights)
            node, spinners, lights = self.pursuer_nodes[uid]
            node.setPos(u.x, u.y, u.z)
            if u.state == "crashed":
                node.setHpr(-u.heading, -25, 70)
                node.setColorScale(0.25, 0.22, 0.2, 1)
                continue
            node.setHpr(-u.heading, 0, 0)
            for sp in spinners:
                sp.setH(sp.getH() + 1500 * dt) if u.kind == "heli" else sp.setR(sp.getR() + 2000 * dt)
            for k, ln in enumerate(lights):
                ln.setColorScale((1, 1, 1, 1) if (k == blink) else (0.15, 0.15, 0.15, 1))

    def _update_camera(self, st, dt):
        h = math.radians(st.heading)
        fwd = Vec3(math.sin(h), math.cos(h), 0)
        L = self.s.spec.visual.length_m
        cockpit = self.cam_mode == "cockpit"
        self.player.hide() if cockpit else self.player.show()
        self.glareshield.show() if cockpit else self.glareshield.hide()
        if cockpit:
            self.camera.reparentTo(self.player)
            self.camera.setPos(-0.3, L * 0.14, 0.25 + L * 0.085 * 0.75)
            self.camera.setHpr(0, -4, 0)
            self.camLens.setFov(80)
            return
        self.camera.reparentTo(self.render)
        target = Vec3(st.x, st.y, st.alt)
        if self.cam_mode == "tower":
            af, _ = self.s.world.nearest_airfield(st.x, st.y)
            tower = Vec3(af.x + af.dir[1] * (af.width / 2 + 55), af.y - af.dir[0] * (af.width / 2 + 55),
                         self.s.world.airfield_elev(af) + 24)
            self.camera.setPos(tower)
            self.camera.lookAt(target)
            self.camLens.setFov(max(8, min(70, math.degrees(math.atan2(L * 3, (target - tower).length())) * 2)))
            return
        self.camLens.setFov(70)
        want = target - fwd * (L * 2.6 + 6) + Vec3(0, 0, L * 0.55 + 1.5)
        if self._cam_pos is None or (self._cam_pos - want).length() > 400:
            self._cam_pos = want  # respawn / teleport: don't sweep across the map
        k = 1 - math.exp(-dt * 4.0)
        self._cam_pos = self._cam_pos + (want - self._cam_pos) * k
        ground = self.s.world.ground(self._cam_pos.x, self._cam_pos.y) + 1.5
        if self._cam_pos.z < ground:
            self._cam_pos.z = ground
        self.camera.setPos(self._cam_pos)
        self.camera.lookAt(target + fwd * L * 1.5 + Vec3(0, 0, 0.5))


def run(session: Session, server=None, graphics: str = "high", bot=None) -> None:
    app = SkyrunnerApp(session, server=server, graphics=graphics, bot=bot)
    props = WindowProperties()
    props.setTitle("Skyrunner - cargo, balance, and the long arm of the law")
    app.win.requestProperties(props)
    session.say("F1 for controls. [J] to see the job board.")
    app.run()
