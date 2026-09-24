"""Station client: a 2D tactical map for the non-flying seats.

  python -m skyrunner.station --connect HOST:47800 --role copilot|spotter|controller
  python -m skyrunner.station --police          # task force vs AI runners, offline

Everything it shows comes from role-filtered snapshots, so a controller only
ever sees radar tracks, tips and their own units.
"""
from __future__ import annotations

import argparse
import math
import sys

from direct.gui.DirectGui import DirectFrame
from direct.gui.OnscreenImage import OnscreenImage
from direct.gui.OnscreenText import OnscreenText
from direct.showbase.ShowBase import ShowBase
from panda3d.core import ClockObject, LineSegs, TextNode, loadPrcFileData

from .roles import Mode, Role
from .world import AIRFIELDS, HALF, World

MAP_SIZE = 1.8
MAP_X0, MAP_Y0 = -1.74, -0.9
PANEL_X = 0.12
RUNNER_TABS = ("load", "jobs", "flight")

HELP = {
    "copilot": "[1] Load  [2] Jobs  [3] Flight   UP/DOWN select  LEFT/RIGHT move item  A loadmaster\n"
               "+/- fuel  F fill ferry  ENTER accept/drop job  K kick  O call boat  V pump  T auto-kick",
    "spotter": "UP/DOWN pick a strip  ENTER send the spotter there (60 s)",
    "controller": "Click a unit, then right-click the map (or click a track) to dispatch.\n"
                  "H heli  I interceptor  C cutter (to mouse)  R recall  E encryption  B aerostat  TAB next unit",
}


def _fmt_km(v: float) -> str:
    return f"{v / 1000:.1f}"


class StationApp(ShowBase):
    def __init__(self, link, role: Role, world: World | None = None, offscreen: bool = False):
        if offscreen:
            loadPrcFileData("", "window-type offscreen\naudio-library-name null\nwin-size 1280 720")
        else:
            loadPrcFileData("", "win-size 1280 720\nwindow-title Skyrunner station\nsync-video 1")
        super().__init__()
        self.link = link
        self.role = Role(role)
        self.world = world or World()
        self.setBackgroundColor(0.04, 0.05, 0.07, 1)
        self.disableMouse()
        self.font = self.loader.loadFont("cmtt12.egg")
        self.tab = "load"
        self.sel = 0
        self.sel_unit: str | None = None
        self.status = ""
        self._pending_acks: list[int] = []
        self._build()
        self._bind()
        self.taskMgr.add(self._tick, "station")

    # ------------------------------------------------------------ layout
    def _build(self):
        from .render.models import minimap_texture

        self.map_root = self.aspect2d.attachNewNode("map")
        OnscreenImage(minimap_texture(self.world, 512), parent=self.map_root,
                      pos=(MAP_X0 + MAP_SIZE / 2, 0, MAP_Y0 + MAP_SIZE / 2), scale=(MAP_SIZE / 2, 1, MAP_SIZE / 2))
        static = LineSegs()
        static.setThickness(2)
        for af in AIRFIELDS:
            static.setColor(1, 1, 1, 1)
            a, b = self.w2m(*af.threshold(0)), self.w2m(*af.threshold(1))
            static.moveTo(a[0], 0, a[1])
            static.drawTo(b[0], 0, b[1])
            mx, my = self.w2m(af.x + 500, af.y + 300)
            OnscreenText(af.code, parent=self.map_root, pos=(mx, my), scale=0.03, fg=(1, 1, 1, 0.9),
                         align=TextNode.ALeft, shadow=(0, 0, 0, 1))
        self.map_root.attachNewNode(static.create())
        self.dyn = self.map_root.attachNewNode("dyn")
        self.labels: list[OnscreenText] = []
        DirectFrame(parent=self.aspect2d, frameColor=(0.08, 0.09, 0.12, 1), frameSize=(PANEL_X - 0.03, 1.8, -1, 1))
        self.title = OnscreenText("", parent=self.aspect2d, pos=(PANEL_X, 0.9), scale=0.05, fg=(1, 0.75, 0.2, 1),
                                  align=TextNode.ALeft, mayChange=True)
        self.panel = OnscreenText("", parent=self.aspect2d, pos=(PANEL_X, 0.82), scale=0.034, fg=(0.9, 0.95, 1, 1),
                                  align=TextNode.ALeft, mayChange=True, font=self.font)
        self.help = OnscreenText(HELP.get(self.role.value, HELP["copilot"]), parent=self.aspect2d,
                                 pos=(PANEL_X, -0.86), scale=0.03, fg=(0.7, 0.7, 0.7, 1), align=TextNode.ALeft,
                                 mayChange=True, font=self.font)
        self.status_text = OnscreenText("", parent=self.aspect2d, pos=(PANEL_X, -0.78), scale=0.035,
                                        fg=(1, 0.5, 0.4, 1), align=TextNode.ALeft, mayChange=True)

    def w2m(self, x: float, y: float) -> tuple[float, float]:
        return (MAP_X0 + (x + HALF) / (2 * HALF) * MAP_SIZE, MAP_Y0 + (y + HALF) / (2 * HALF) * MAP_SIZE)

    def m2w(self, mx: float, my: float) -> tuple[float, float]:
        return ((mx - MAP_X0) / MAP_SIZE * 2 * HALF - HALF, (my - MAP_Y0) / MAP_SIZE * 2 * HALF - HALF)

    # ------------------------------------------------------------ input
    def _bind(self):
        for k in ("1", "2", "3"):
            self.accept(k, self._set_tab, [RUNNER_TABS[int(k) - 1]])
        keys = {"arrow_up": "up", "arrow_down": "down", "arrow_left": "left", "arrow_right": "right",
                "enter": "enter", "a": "a", "+": "+", "=": "+", "-": "-", "f": "f", "k": "k", "o": "o", "v": "v",
                "t": "t", "h": "h", "i": "i", "c": "c", "r": "r", "e": "e", "b": "b", "tab": "tab"}
        for k, name in keys.items():
            self.accept(k, self._key, [name])
        self.accept("mouse1", self._click, [1])
        self.accept("mouse3", self._click, [3])
        self.accept("escape", sys.exit)

    def _set_tab(self, tab: str):
        self.tab, self.sel = tab, 0

    def _cmd(self, name: str, **args):
        seq = self.link.send_command(name, **args)
        if hasattr(self.link, "last_result"):  # local: result is immediate
            self.status = "" if self.link.last_result[0] else self.link.last_result[1]
        else:  # network: the ack arrives a few frames later
            self._pending_acks.append(seq)
            self.status = ""

    def _check_acks(self):
        acks = getattr(self.link, "acks", None)
        if not acks:
            return
        for seq in [s for s in self._pending_acks if s in acks]:
            self._pending_acks.remove(seq)
            ok, msg = acks.pop(seq)
            if not ok:
                self.status = msg

    def _mouse_world(self) -> tuple[float, float] | None:
        mw = self.mouseWatcherNode
        if mw is None or not mw.hasMouse():
            return None
        m = mw.getMouse()
        ax = m.x * self.getAspectRatio()
        if not (MAP_X0 <= ax <= MAP_X0 + MAP_SIZE and MAP_Y0 <= m.y <= MAP_Y0 + MAP_SIZE):
            return None
        return self.m2w(ax, m.y)

    def _click(self, button: int):
        pos = self._mouse_world()
        snap = self.link.snapshot()
        if pos is None or snap is None or self.role != Role.CONTROLLER:
            return
        units = snap.get("units", [])
        tracks = snap.get("tracks", [])
        near = lambda items: min(items, key=lambda o: math.hypot(o["x"] - pos[0], o["y"] - pos[1]), default=None)  # noqa: E731
        if button == 1:
            u = near(units)
            if u and math.hypot(u["x"] - pos[0], u["y"] - pos[1]) < 1200:
                self.sel_unit = u["id"]
                return
            t = near(tracks)
            if self.sel_unit and t and math.hypot(t["x"] - pos[0], t["y"] - pos[1]) < 1200:
                self._cmd("dispatch", unit=self.sel_unit, target=t["id"])
        elif button == 3 and self.sel_unit:
            self._cmd("dispatch", unit=self.sel_unit, x=pos[0], y=pos[1])

    def _key(self, k: str):
        snap = self.link.snapshot()
        if snap is None:
            return
        if self.role == Role.CONTROLLER:
            self._law_key(k, snap)
        elif self.role == Role.SPOTTER:
            if k in ("up", "down"):
                self.sel = (self.sel + (1 if k == "down" else -1)) % len(AIRFIELDS)
            elif k == "enter":
                self._cmd("spotter_move", code=AIRFIELDS[self.sel].code)
        else:
            self._runner_key(k, snap)

    def _runner_key(self, k: str, snap: dict):
        if k in ("k", "o", "v", "t"):
            self._cmd({"k": "kick", "o": "call_boat", "v": "pump", "t": "auto_kick"}[k])
            return
        if self.tab == "load":
            items = snap["loadout"]["items"]
            if k in ("up", "down") and items:
                self.sel = (self.sel + (1 if k == "down" else -1)) % len(items)
            elif k in ("left", "right") and items:
                self._cmd("move_item", item_id=items[min(self.sel, len(items) - 1)]["id"], direction=1 if k == "right" else -1)
            elif k == "a":
                self._cmd("loadmaster")
            elif k in ("+", "-"):
                lo = snap["loadout"]
                self._cmd("set_fuel", lb=lo["fuel"] + (0.1 if k == "+" else -0.1) * lo["fuel_cap"])
            elif k == "f":
                self._cmd("fill_ferry", lb=10_000)
        elif self.tab == "jobs":
            rows = [("board", j) for j in snap["board"]] + [("active", j) for j in snap["jobs"]]
            if k in ("up", "down") and rows:
                self.sel = (self.sel + (1 if k == "down" else -1)) % len(rows)
            elif k == "enter" and rows:
                kind, j = rows[min(self.sel, len(rows) - 1)]
                self._cmd("accept_job" if kind == "board" else "drop_job", job_id=j["id"])

    def _law_key(self, k: str, snap: dict):
        pos = self._mouse_world()
        units = [u for u in snap["units"] if u["state"] != "crashed"]
        if k == "tab" and units:
            ids = [u["id"] for u in units]
            self.sel_unit = ids[(ids.index(self.sel_unit) + 1) % len(ids)] if self.sel_unit in ids else ids[0]
        elif k in ("h", "i", "c"):
            kind = {"h": "heli", "i": "interceptor", "c": "cutter"}[k]
            args = {"x": pos[0], "y": pos[1]} if pos else {}
            self._cmd("launch", kind=kind, **args)
        elif k == "r" and self.sel_unit:
            self._cmd("recall", unit=self.sel_unit)
        elif k == "e":
            self._cmd("encrypt", on=not snap.get("encrypted"))
        elif k == "b":
            self._cmd("aerostat", on=snap.get("aerostat") == "down")

    # ------------------------------------------------------------ drawing
    def _tick(self, task):
        dt = min(ClockObject.getGlobalClock().getDt(), 0.1)
        self.link.tick(dt)
        snap = self.link.snapshot()
        err = getattr(self.link, "error", None)
        if snap is None:
            self.title.setText("Connecting..." if not err else f"Disconnected: {err}")
            return task.cont
        self._draw(snap)
        self._check_acks()
        self.status_text.setText(self.status or (f"Link lost: {err}" if err and not self.link.alive else ""))
        return task.cont

    def _label(self, i: int, text: str, x: float, y: float, color) -> None:
        while len(self.labels) <= i:
            self.labels.append(OnscreenText("", parent=self.dyn.getParent(), scale=0.026, align=TextNode.ALeft,
                                            mayChange=True, shadow=(0, 0, 0, 1)))
        lab = self.labels[i]
        lab.setText(text)
        lab.setPos(x, y)
        lab["fg"] = color

    def _draw(self, snap: dict):
        self.dyn.removeNode()
        self.dyn = self.map_root.attachNewNode("dyn")
        ls = LineSegs()
        ls.setThickness(2)
        labels: list[tuple[str, float, float, tuple]] = []

        def circle(x, y, r, color, n=24):
            ls.setColor(*color)
            for k in range(n + 1):
                a = 2 * math.pi * k / n
                mx, my = self.w2m(x + r * math.cos(a), y + r * math.sin(a))
                ls.drawTo(mx, 0, my) if k else ls.moveTo(mx, 0, my)

        def arrow(x, y, hdg, color, size=0.018):
            mx, my = self.w2m(x, y)
            h = math.radians(hdg)
            fx, fy = math.sin(h), math.cos(h)
            ls.setColor(*color)
            ls.moveTo(mx + fx * size, 0, my + fy * size)
            ls.drawTo(mx - fx * size * 0.6 + fy * size * 0.6, 0, my - fy * size * 0.6 - fx * size * 0.6)
            ls.drawTo(mx - fx * size * 0.6 - fy * size * 0.6, 0, my - fy * size * 0.6 + fx * size * 0.6)
            ls.drawTo(mx + fx * size, 0, my + fy * size)

        def cross(x, y, color, s=0.01):
            mx, my = self.w2m(x, y)
            ls.setColor(*color)
            ls.moveTo(mx - s, 0, my - s)
            ls.drawTo(mx + s, 0, my + s)
            ls.moveTo(mx - s, 0, my + s)
            ls.drawTo(mx + s, 0, my - s)

        if snap["side"] == "law":
            self._draw_law(snap, circle, arrow, cross, labels, ls)
        else:
            self._draw_runner(snap, circle, arrow, cross, labels, ls)
        self.dyn.attachNewNode(ls.create())
        for i, (text, x, y, col) in enumerate(labels[:60]):
            mx, my = self.w2m(x, y)
            self._label(i, text, mx + 0.012, my + 0.008, col)
        for lab in self.labels[len(labels):]:
            lab.setText("")

    def _draw_runner(self, snap, circle, arrow, cross, labels, ls):
        ac = snap.get("aircraft")
        for j in snap["jobs"]:
            circle(j["x"], j["y"], 600, (0.3, 1, 0.3, 1))
            labels.append((j["dest"], j["x"], j["y"], (0.4, 1, 0.4, 1)))
        for b in snap["boats"]:
            arrow(b["x"], b["y"], b["heading"], (0.3, 0.8, 1, 1), 0.014)
            labels.append((f"{b['id']} {b['state']} [{b['cargo']}]", b["x"], b["y"], (0.5, 0.85, 1, 1)))
        for bl in snap["bales"]:
            cross(bl["x"], bl["y"], (1, 0.9, 0.3, 1), 0.005)
        for it in snap["intel"]:
            cross(it["x"], it["y"], (1, 0.3, 0.3, 1) if it["age"] < 10 else (0.6, 0.3, 0.3, 1))
            labels.append((f"{it['unit']} {it['source']} {it['age']:.0f}s", it["x"], it["y"], (1, 0.5, 0.5, 1)))
        for sp in snap["spotters"]:
            af = next(a for a in AIRFIELDS if a.code == sp["code"])
            circle(af.x, af.y, 5000, (1, 1, 0.4, 0.5))
        if ac:
            arrow(ac["x"], ac["y"], ac["heading"], (1, 1, 0, 1), 0.024)
        self.title.setText(f"{self.role.value.upper()} - {snap['mode']}   ${snap['money']:,}")
        lines = []
        if ac:
            lines += [
                f"{ac['type']}  {ac['phase']}{' @' + ac['location'] if ac['location'] else ''}",
                f"IAS {ac['ias']:.0f}kt  GS {ac['gs']:.0f}  ALT {ac['alt'] / 0.3048:.0f}ft  HDG {ac['heading']:.0f}",
                f"FUEL {ac['fuel']:.0f} lb + ferry {ac['ferry_fuel']:.0f}  range {ac['range_km']:.0f} km"
                f"  {'PUMP ON' if ac['pumping'] else ''}",
                f"XPDR {'ON ' + ac['squawk'] if ac['transponder'] else 'OFF'}  AP {'ON' if ac['autopilot'] else 'off'}"
                f"  RADAR {ac['detector'] or '-'}  WANTED {'*' * ac['wanted']}",
                f"KICK queue {ac['kick_queue']}  auto-kick {'on' if ac['auto_kick'] else 'off'}",
            ]
            if ac["outcome"]:
                lines.append(ac["outcome"])
        if "campaign" in snap:
            c = snap["campaign"]
            lines += ["", f"CH{c['chapter']} {c['year']} {c['title']}"] + c["objectives"]
        lines.append("")
        tab = self.tab if self.role == Role.COPILOT else None
        if tab == "load":
            lo = snap["loadout"]
            wb = lo["wb"]
            lines.append(f"LOAD  {wb['weight']:.0f}/{wb['mtow']:.0f} lb  CG {wb['cg']:.1f} ({wb['fwd']:.1f}-{wb['aft']:.1f})"
                         f"  {'OK' if wb['ok'] else 'OUT OF LIMITS'}  crew {lo['crew']}")
            for i, it in enumerate(lo["items"]):
                cur = ">" if i == self.sel else " "
                pend = f" loading {it['pending']:.0f}s" if it["pending"] else ""
                lines.append(f"{cur} {it['label'][:14]:<14} {it['weight']:5.0f} -> {it['station'] or 'RAMP'}{pend}")
        elif tab == "jobs":
            rows = [("board", j) for j in snap["board"]] + [("active", j) for j in snap["jobs"]]
            for i, (kind, j) in enumerate(rows):
                cur = ">" if i == self.sel else " "
                lines.append(f"{cur} {'+' if kind == 'board' else '*'} {j['title'][:34]:<34} ${j['payout']:,}")
            if not rows:
                lines.append("(park at a field to see its board)")
        elif tab == "flight" or tab is None:
            lines.append("SCANNER:" if snap.get("scanner") is not None else "(no scanner fitted)")
            lines += [f"  {s[:56]}" for s in (snap.get("scanner") or [])[-6:]]
            if self.role == Role.SPOTTER:
                lines.append("")
                lines.append("Send spotter to:")
                for i, af in enumerate(AIRFIELDS):
                    lines.append(f"{'>' if i == self.sel else ' '} {af.code} {af.name}")
        lines.append("")
        lines += snap["messages"][-5:]
        self.panel.setText("\n".join(lines))

    def _draw_law(self, snap, circle, arrow, cross, labels, ls):
        for r in snap["radars"]:
            circle(r["x"], r["y"], r["range"], (1, 0.25, 0.25, 0.6) if r["active"] else (0.4, 0.2, 0.2, 0.4), 48)
        for tip in snap["tips"]:
            circle(tip["x"], tip["y"], tip["r"], (1, 0.8, 0.2, 0.8))
            labels.append((tip["text"][:28], tip["x"], tip["y"], (1, 0.85, 0.3, 1)))
        for t in snap["tracks"]:
            mx, my = self.w2m(t["x"], t["y"])
            fresh = t["age"] < 3
            ls.setColor(*((1, 0.3, 0.3, 1) if fresh else (0.6, 0.3, 0.3, 1)))
            s = 0.01
            ls.moveTo(mx - s, 0, my - s)
            for px, py in ((mx + s, my - s), (mx + s, my + s), (mx - s, my + s), (mx - s, my - s)):
                ls.drawTo(px, 0, py)
            ls.moveTo(mx, 0, my)
            ex, ey = self.w2m(t["x"] + t["vx"] * 60, t["y"] + t["vy"] * 60)
            ls.drawTo(ex, 0, ey)
            name = t["squawk"] or f"TRK {t['id']}"
            labels.append((f"{name} {t['source']} {t['age']:.0f}s", t["x"], t["y"], (1, 0.5, 0.5, 1)))
        for b in snap["boats"]:
            arrow(b["x"], b["y"], b["heading"], (1, 0.6, 0.2, 1), 0.014)
            labels.append((f"go-fast {b['state']}", b["x"], b["y"], (1, 0.7, 0.3, 1)))
        for u in snap["units"]:
            col = (0.4, 0.7, 1, 1) if u["id"] != self.sel_unit else (1, 1, 1, 1)
            if u["state"] == "crashed":
                cross(u["x"], u["y"], (0.5, 0.5, 0.5, 1))
                continue
            arrow(u["x"], u["y"], u["heading"], col, 0.016)
            labels.append((f"{u['id']} {u['state']}{' EYES ON' if u['sees'] else ''}", u["x"], u["y"], col))
        self.title.setText(f"TASK FORCE DESK - {snap['mode']}")
        cases = sorted(snap["cases"], key=lambda c: -c["suspicion"])
        sc, rs = snap["score"], snap["runner_score"]
        lines = [
            f"Stock  heli {snap['stock'].get('heli', 0)}  interceptor {snap['stock'].get('interceptor', 0)}"
            f"  cutter {snap['stock'].get('cutter', 0)}",
            f"Radio {'ENCRYPTED' if snap['encrypted'] else 'plain (scanners can hear you)'}   Aerostat {snap['aerostat']}",
            f"Score: busts {sc['busts']}  boats {sc['boats_seized']}  bales {sc['bales_seized']}"
            f"  | runners: bales in {rs['bales_delivered']}  escaped {rs['escapes']}",
            f"Selected: {self.sel_unit or '-'}",
            "",
            "CASES:",
        ]
        lines += [f"  {c['id']:<10} susp {c['suspicion']:3.0f}%  wanted {'*' * c['wanted']}{'  TIPPED' if c['tipped'] else ''}"
                  for c in cases[:6]] or ["  (quiet)"]
        lines += ["", "UNITS:"]
        lines += [f"  {u['id']:<10} {u['kind']:<11} {u['state']:<8} {('-> ' + u['target']) if u['target'] else ''}"
                  for u in snap["units"]] or ["  (none airborne)"]
        lines += ["", "RADIO / ALERTS:"] + [f"  {m[:58]}" for m in snap["messages"][-9:]]
        self.panel.setText("\n".join(lines))


def main() -> None:
    ap = argparse.ArgumentParser(description="Skyrunner station (co-pilot / spotter / task-force desk)")
    ap.add_argument("--connect", help="HOST:PORT of the pilot's game (started with --host)")
    ap.add_argument("--role", default="copilot", choices=["copilot", "spotter", "controller"])
    ap.add_argument("--name", default="player")
    ap.add_argument("--police", action="store_true", help="offline: run the task-force desk against AI runners")
    ap.add_argument("--seed", type=int, default=3)
    args = ap.parse_args()
    if args.police:
        from .game import Session
        from .net.client import LocalLink

        sess = Session(mode=Mode.POLICE, seed=args.seed, humans={Role.CONTROLLER: args.name})
        link, role = LocalLink(sess, Role.CONTROLLER), Role.CONTROLLER
    elif args.connect:
        from .net.client import NetClient

        host, _, port = args.connect.rpartition(":")
        link, role = NetClient(host or "127.0.0.1", int(port), args.name, args.role).start(), Role(args.role)
    else:
        ap.error("use --connect HOST:PORT or --police")
    StationApp(link, role).run()


if __name__ == "__main__":
    main()
