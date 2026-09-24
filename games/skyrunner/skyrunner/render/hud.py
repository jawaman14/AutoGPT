"""HUD overlay, minimap and the keyboard-driven ground menus."""
from __future__ import annotations

import math

from direct.gui.DirectGui import DirectFrame
from direct.gui.OnscreenImage import OnscreenImage
from direct.gui.OnscreenText import OnscreenText
from panda3d.core import LineSegs, TextNode

from ..aircraft import ROSTER
from ..game import FUEL_PRICE_PER_LB, GEAR, LOADMASTER_FEE, Session
from ..loadout import PILOT_LB
from ..world import AIRFIELD_BY_CODE, HALF

_MONO = None


def mono():
    """Panda3D ships a Computer Modern typewriter font; menus use fixed columns."""
    global _MONO
    if _MONO is None:
        from direct.showbase import ShowBaseGlobal

        _MONO = ShowBaseGlobal.base.loader.loadFont("cmtt12.egg")
    return _MONO

WHITE = (1, 1, 1, 1)
AMBER = (1, 0.75, 0.2, 1)
RED = (1, 0.25, 0.2, 1)
GREEN = (0.4, 1, 0.45, 1)
CYAN = (0.5, 0.9, 1, 1)


def _text(parent, pos, scale=0.045, fg=WHITE, align=TextNode.ALeft, mayChange=True, font=None):
    kw = {"font": font} if font is not None else {}
    return OnscreenText(
        text="", parent=parent, pos=pos, scale=scale, fg=fg, align=align,
        shadow=(0, 0, 0, 0.8), mayChange=mayChange, **kw,
    )


def bearing_to(x0, y0, x1, y1) -> float:
    return math.degrees(math.atan2(x1 - x0, y1 - y0)) % 360


def papi(alt: float, dist_m: float, field_elev: float) -> str:
    """PAPI lights left->right. 'W' white, 'R' red. 2W2R = on a 3.5 deg path."""
    if dist_m <= 1:
        return "...."
    ang = math.degrees(math.atan2(alt - field_elev, dist_m))
    whites = sum(ang > t for t in (2.9, 3.3, 3.7, 4.1))
    return "W" * whites + "R" * (4 - whites)


class Hud:
    def __init__(self, base, session: Session):
        self.base = base
        self.s = session
        self.flight = _text(base.a2dTopLeft, (0.05, -0.08), 0.045, fg=GREEN, font=mono())
        self.status = _text(base.a2dTopRight, (-0.05, -0.08), 0.045, align=TextNode.ARight)
        self.jobs = _text(base.a2dTopRight, (-0.05, -0.42), 0.038, fg=CYAN, align=TextNode.ARight)
        self.msgs = _text(base.a2dBottomLeft, (0.05, 0.42), 0.042)
        self.warn = _text(base.aspect2d, (0, 0.55), 0.08, fg=RED, align=TextNode.ACenter)
        self.center = _text(base.aspect2d, (0, 0.1), 0.06, fg=AMBER, align=TextNode.ACenter)
        self.hint = _text(base.a2dBottomCenter, (0, 0.05), 0.04, fg=(0.85, 0.85, 0.85, 1), align=TextNode.ACenter)
        self.papi_nodes = [
            _text(base.a2dBottomCenter, (-0.09 + k * 0.06, 0.16), 0.09) for k in range(4)
        ]
        self.papi_label = _text(base.a2dBottomCenter, (0.0, 0.24), 0.035, align=TextNode.ACenter)
        self.intel = _text(base.a2dBottomRight, (-0.05, 0.72), 0.034, fg=(1, 0.8, 0.5, 1), align=TextNode.ARight)
        self.objectives = _text(base.a2dTopRight, (-0.05, -0.72), 0.036, fg=AMBER, align=TextNode.ARight)
        self.minimap = Minimap(base, session)
        self.throttle_bar = self._bar(base.a2dBottomLeft, (0.05, 0.06), GREEN)
        self.bust_bar = self._bar(base.aspect2d, (-0.3, 0.42), RED, width=0.6, vertical=False)
        self.rival_bar = self._bar(base.aspect2d, (-0.3, 0.38), (0.8, 0.3, 1, 1), width=0.6, vertical=False)

    def _bar(self, parent, pos, color, width=0.04, vertical=True):
        frame = DirectFrame(parent=parent, frameColor=(0, 0, 0, 0.5),
                            frameSize=(0, width, 0, 0.3) if vertical else (0, width, 0, 0.025), pos=(pos[0], 0, pos[1]))
        fill = DirectFrame(parent=frame, frameColor=color,
                           frameSize=(0, width, 0, 0.3) if vertical else (0, width, 0, 0.025))
        fill.vertical = vertical
        return frame, fill

    @staticmethod
    def _set_bar(bar, frac):
        frame, fill = bar
        frac = max(0.001, min(1.0, frac))
        if fill.vertical:
            fill.setScale(1, 1, frac)
        else:
            fill.setScale(frac, 1, 1)

    def update(self, cam_mode: str, mouse_yoke: bool):
        s, st = self.s, self.s.state
        c = s.fm.controls
        if st is None:
            return
        lo = s.loadout
        flaps = int(round(c.flaps * 3))
        hours, range_km = s.range_estimate()
        ferry = lo.ferry_fuel_lb()
        self.flight.setText(
            f"IAS  {st.ias_kts:5.0f} kt\n"
            f"GS   {st.gs_kts:5.0f} kt\n"
            f"ALT  {st.alt / 0.3048:5.0f} ft\n"
            f"AGL  {max(0.0, st.agl / 0.3048 - s.fm.mass.gear_height_ft):5.0f} ft\n"
            f"VS   {st.vs_fpm:+5.0f} fpm\n"
            f"HDG  {st.heading % 360:5.0f}\n"
            f"PWR  {c.throttle * 100:5.0f} %   RPM {st.rpm:4.0f}\n"
            f"FLAP {flaps}/3   TRIM {-c.pitch_trim:+.2f}\n"
            f"FUEL {st.fuel_lb:5.0f} lb" + (f" +{ferry:.0f} ferry{' PUMP' if s.pumping else ''}" if ferry or lo.ferry_tanks() else "") + "\n"
            + (f"RNG  {range_km:5.0f} km  ({hours * 60:.0f} min)\n" if not st.on_ground else "RNG     -- (airborne only)\n") +
            f"WT   {st.weight_lb:5.0f} lb  CG {st.cg_in:.1f}in\n"
            f"XPDR {'ON ' + s.squawk if s.transponder else 'OFF'}   AP {'ON' if s.autopilot.engaged else '--'}"
            f"{'   KICKING' if s.kick_queue else ''}\n"
            f"{'BRAKE ' if c.brake > 0.5 else ''}{'YOKE:MOUSE ' if mouse_yoke else ''}CAM:{cam_mode}"
        )
        self._set_bar(self.throttle_bar, c.throttle)
        wanted = s.police.wanted
        stars = "*" * wanted + "." * (3 - wanted)
        det = ""
        if "detector" in s.gear:
            level = s.police.detector()
            det = {"LOCK": "  RADAR LOCK", "PAINT": "  radar paint"}.get(level, "  radar clear")
        susp = f"  suspicion {s.police.suspicion:3.0f}%" if s.police.suspicion > 1 and not wanted else ""
        self.status.setText(
            f"${s.money:,}\n{s.spec.name}\n"
            f"WANTED [{stars}]{det}{susp}\n"
            + (f"At {AIRFIELD_BY_CODE[s.location].name}" if s.location else "")
        )
        self.status["fg"] = RED if wanted else WHITE
        job_lines = []
        for j in s.active_jobs[:6]:
            jx, jy = s.job_xy(j)
            d = math.hypot(jx - st.x, jy - st.y) / 1000
            brg = bearing_to(st.x, st.y, jx, jy)
            tl = j.time_left(s.time)
            tls = f" {int(tl // 60)}:{int(tl % 60):02d}" if tl is not None else ""
            extra = ""
            if j.is_airdrop:
                boat = s.maritime.boat(j.boat_id) if j.boat_id else None
                left = sum(1 for i in lo.items.values() if i.job_id == j.id)
                extra = f" [{left} aboard, boat {boat.state if boat else '?'}]"
            job_lines.append(f"{'!' if j.hot else ''}{j.dest_label()} {d:4.1f}km brg {brg:03.0f}{tls}  ${j.payout:,}{extra}")
        self.jobs.setText("\n".join(job_lines))
        intel_lines = [f"SCAN {text[:52]}" for t, text in s.scanner_log[-3:] if s.time - t < 40]
        self.intel.setText("\n".join(intel_lines))
        camp = s.campaign
        self.objectives.setText(
            (f"{camp.chapter.year} - {camp.chapter.title}\n" + "\n".join(camp.objective_lines())) if camp else "")
        now = s.time
        self.msgs.setText("\n".join(m for t, m in s.messages if now - t < 12))
        warns = []
        if st.stall_warning:
            warns.append("STALL")
        if s.police.bust_meter > 1:
            warns.append("POLICE ON YOUR TAIL")
        if s.police.rival_meter > 1:
            warns.append("RIVALS CLOSING")
        if st.fuel_lb < 20 and not st.on_ground:
            warns.append("LOW FUEL")
        if c.flaps > 0 and st.ias_kts > s.spec.max_flap_kts + 5:
            warns.append("FLAP OVERSPEED")
        self.warn.setText("  ".join(warns))
        self._set_bar(self.bust_bar, s.police.bust_meter / 100)
        self._set_bar(self.rival_bar, s.police.rival_meter / 100)
        self.bust_bar[0].show() if s.police.bust_meter > 1 else self.bust_bar[0].hide()
        self.rival_bar[0].show() if s.police.rival_meter > 1 else self.rival_bar[0].hide()

        if s.phase in ("crashed", "busted"):
            self.center.setText(s.last_outcome + "\n\nPress ENTER to continue")
        elif s.parked:
            wb = lo.compute()
            flag = "" if wb.ok else "   !! LOAD OUT OF LIMITS !!"
            self.center.setText("")
            busy = f"   loading... {sum(lo.pending.values()):.0f} crew-s" if lo.pending else ""
            self.hint.setText(f"[J] Jobs  [L] Load & fuel  [H] Hangar & gear  [F1] Help{flag}{busy}")
        else:
            self.center.setText("")
            self.hint.setText("")
        self._update_papi(st)
        self.minimap.update()

    def _update_papi(self, st):
        s = self.s
        dests = [AIRFIELD_BY_CODE[j.dest] for j in s.active_jobs if not j.is_airdrop]
        af, dist = None, 1e9
        for a in dests or s.world.airfields:
            for end in (0, 1):
                tx, ty = a.threshold(end)
                d = math.hypot(tx - st.x, ty - st.y)
                # only the end you'd be approaching: runway direction must point away from you
                ux, uy = a.dir
                sgn = 1 if end == 0 else -1
                if ((a.x - tx) * (st.x - tx) + (a.y - ty) * (st.y - ty)) > 0:
                    continue
                if d < dist:
                    af, dist, aim = a, d, (tx + sgn * ux * 60, ty + sgn * uy * 60)
        if af is None or dist > 6000 or st.on_ground:
            for n in self.papi_nodes:
                n.setText("")
            self.papi_label.setText("")
            return
        d_aim = math.hypot(aim[0] - st.x, aim[1] - st.y)
        lights = papi(st.alt - s.fm.mass.gear_height_ft * 0.3048, d_aim, s.world.airfield_elev(af))
        for n, ch in zip(self.papi_nodes, lights):
            n.setText("o")
            n["fg"] = WHITE if ch == "W" else RED
        self.papi_label.setText(f"{af.code} {af.length:.0f}x{af.width:.0f}m  {dist / 1000:.1f}km")


class Minimap:
    SIZE = 0.42

    def __init__(self, base, session: Session):
        from .models import minimap_texture

        self.s = session
        self.root = base.a2dBottomRight.attachNewNode("minimap")
        self.root.setPos(-self.SIZE - 0.04, 0, 0.04)
        self.big = False
        tex = minimap_texture(session.world)
        self.img = OnscreenImage(tex, parent=self.root, scale=(self.SIZE / 2, 1, self.SIZE / 2),
                                 pos=(self.SIZE / 2, 0, self.SIZE / 2))
        self.static = self.root.attachNewNode("static")
        self.dynamic = self.root.attachNewNode("dyn")
        self.labels = []
        self._draw_static()

    def to_map(self, x, y):
        return (x + HALF) / (2 * HALF) * self.SIZE, (y + HALF) / (2 * HALF) * self.SIZE

    def _draw_static(self):
        ls = LineSegs()
        ls.setThickness(3)
        for af in self.s.world.airfields:
            ls.setColor(1, 1, 1, 1) if af.kind in ("hub", "regional") else ls.setColor(1, 0.8, 0.3, 1)
            a, b = af.threshold(0), af.threshold(1)
            ls.moveTo(*self._p(*a))
            ls.drawTo(*self._p(*b))
            t = OnscreenText(af.code, parent=self.static, pos=self.to_map(af.x + 600, af.y + 400), scale=0.022,
                             fg=(1, 1, 1, 0.9), align=TextNode.ALeft, shadow=(0, 0, 0, 1))
            self.labels.append(t)
        for af in self.s.world.airfields:
            if af.radar_km:
                ls.setColor(1, 0.2, 0.2, 0.5)
                r = af.radar_km * 1000
                for k in range(49):
                    a = 2 * math.pi * k / 48
                    p = self._p(af.x + r * math.cos(a), af.y + r * math.sin(a))
                    ls.drawTo(*p) if k else ls.moveTo(*p)
        self.static.attachNewNode(ls.create())

    def _p(self, x, y):
        mx, my = self.to_map(max(-HALF, min(HALF, x)), max(-HALF, min(HALF, y)))
        return mx, 0, my

    def toggle(self):
        self.big = not self.big
        self.root.setScale(2.2 if self.big else 1.0)
        self.root.setPos((-self.SIZE * 2.2 - 0.3, 0, 0.3) if self.big else (-self.SIZE - 0.04, 0, 0.04))

    def update(self):
        self.dynamic.removeNode()
        self.dynamic = self.root.attachNewNode("dyn")
        st = self.s.state
        ls = LineSegs()
        ls.setThickness(3)
        s = self.s

        def cross(x, y, color, r=0.006):
            ls.setColor(*color)
            cx, _, cy = self._p(x, y)
            ls.moveTo(cx - r, 0, cy - r)
            ls.drawTo(cx + r, 0, cy + r)
            ls.moveTo(cx - r, 0, cy + r)
            ls.drawTo(cx + r, 0, cy - r)

        for j in s.active_jobs:
            jx, jy = s.job_xy(j)
            ls.setColor(*((0.3, 0.8, 1, 1) if j.is_airdrop else (0.3, 1, 0.3, 1)))
            cx, _, cy = self._p(jx, jy)
            for k in range(13):
                a = 2 * math.pi * k / 12
                p = (cx + 0.012 * math.cos(a), 0, cy + 0.012 * math.sin(a))
                ls.drawTo(*p) if k else ls.moveTo(*p)
        for b in s.maritime.boats:
            if b.kind == "gofast" and b.state not in ("delivered",):
                cross(b.x, b.y, (0.3, 0.9, 1, 1), 0.005)
        for bl in s.maritime.bales:
            if bl.state == "floating":
                cross(bl.x, bl.y, (1, 0.9, 0.3, 1), 0.003)
        # police: only what you know - eyeballs, scanner, spotters
        known = {k: (v[1], v[2]) for k, v in s.intel.items() if v[0] <= s.time}
        if st:
            for u in s.police.units:
                if u.state != "crashed" and math.dist((u.x, u.y, u.z), (st.x, st.y, st.alt)) < 4500:
                    known[u.id] = (u.x, u.y)
            for c in s.maritime.boats:
                if c.kind == "cutter" and math.hypot(c.x - st.x, c.y - st.y) < 9000:
                    known[c.id] = (c.x, c.y)
        for uid, (x, y) in known.items():
            cross(x, y, (0.8, 0.3, 1, 1) if uid.startswith("Rival") else (0.3, 0.5, 1, 1))
        if st:
            h = math.radians(st.heading)
            cx, _, cy = self._p(st.x, st.y)
            fx, fy = math.sin(h), math.cos(h)
            ls.setColor(1, 1, 0, 1)
            ls.moveTo(cx + fx * 0.016, 0, cy + fy * 0.016)
            ls.drawTo(cx - fx * 0.008 + fy * 0.008, 0, cy - fy * 0.008 - fx * 0.008)
            ls.drawTo(cx - fx * 0.008 - fy * 0.008, 0, cy - fy * 0.008 + fx * 0.008)
            ls.drawTo(cx + fx * 0.016, 0, cy + fy * 0.016)
        self.dynamic.attachNewNode(ls.create())


# ======================================================================= menus
class Menu:
    title = ""

    def __init__(self, base, session: Session):
        self.base = base
        self.s = session
        self.sel = 0
        self.frame = DirectFrame(parent=base.aspect2d, frameColor=(0.02, 0.03, 0.05, 0.85),
                                 frameSize=(-1.25, 1.25, -0.8, 0.85))
        self.header = _text(self.frame, (-1.2, 0.76), 0.06, fg=AMBER)
        self.body = _text(self.frame, (-1.2, 0.64), 0.042, font=mono())
        self.footer = _text(self.frame, (-1.2, -0.70), 0.036, fg=(0.8, 0.8, 0.8, 1), font=mono())
        self.extra = self.frame.attachNewNode("extra")
        self.hide()

    def show(self):
        self.sel = 0
        self.frame.show()
        self.refresh()

    def hide(self):
        self.frame.hide()

    @property
    def visible(self) -> bool:
        return not self.frame.isHidden()

    def rows(self) -> list:
        return []

    def key(self, k: str):
        n = max(1, len(self.rows()))
        if k == "up":
            self.sel = (self.sel - 1) % n
        elif k == "down":
            self.sel = (self.sel + 1) % n
        self.refresh()

    def refresh(self):
        pass


class JobMenu(Menu):
    def rows(self):
        board = self.s.boards.get(self.s.location, [])
        return [("board", j) for j in board] + [("active", j) for j in self.s.active_jobs]

    def key(self, k):
        if k == "enter":
            rows = self.rows()
            if rows:
                kind, job = rows[min(self.sel, len(rows) - 1)]
                if kind == "board":
                    err = self.s.accept_job(job)
                    self.s.say(err or f"Accepted: {job.title}. Check your load [L]!")
                else:
                    self.s.drop_job(job)
        super().key(k)

    def refresh(self):
        s = self.s
        af = AIRFIELD_BY_CODE[s.location]
        self.header.setText(f"JOB BOARD - {af.name} ({af.length:.0f} m {af.surface})")
        lines = []
        rows = self.rows()
        self.sel = min(self.sel, max(0, len(rows) - 1))
        est_w = s.loadout.compute().weight_lb
        for i, (kind, j) in enumerate(rows):
            if i == 0 and kind == "board":
                lines.append("-- available --")
            if kind == "active" and (i == 0 or rows[i - 1][0] == "board"):
                lines.append("-- on board (ENTER to drop) --")
            jx, jy = s.job_xy(j)
            dist = math.hypot(jx - af.x, jy - af.y) / 1000
            pax = sum(1 for it in j.items if it.kind == "passenger")
            cur = ">" if i == self.sel else " "
            if j.is_airdrop:
                where = f"drop at sea, {len(j.items)} bales, paid per bale at the cove"
            else:
                dst = AIRFIELD_BY_CODE[j.dest]
                roll = s.spec.est_landing_roll(est_w + (j.weight_lb if kind == "board" else 0), s.world.airfield_elev(dst))
                where = f"strip {dst.length:.0f} m (est. roll {roll:.0f} m)"
            lines.append(
                f"{cur} {'[HOT] ' if j.hot else ''}{j.title}\n"
                f"      ${j.payout:,}  {j.weight_lb:.0f} lb  {pax} pax  {dist:.1f} km  {where}"
                + (f"  {int(j.deadline_s // 60)} min" if j.deadline_s else "")
                + (f"\n      {j.notes}" if j.notes else "")
            )
        self.body.setText("\n".join(lines) or "No work here right now.")
        self.footer.setText("UP/DOWN select   ENTER accept/drop   ESC close")


class LoadMenu(Menu):
    def rows(self):
        return sorted(self.s.loadout.items.values(), key=lambda i: (i.job_id, i.id))

    def key(self, k):
        s = self.s
        items = self.rows()
        if k in ("left", "right") and items:
            s.cycle_item(items[min(self.sel, len(items) - 1)].id, 1 if k == "right" else -1)
        elif k == "a":
            s.hire_loadmaster()
        elif k in ("+", "-"):
            cap = s.loadout.mass.fuel_capacity_lb
            s.set_fuel(s.fm.fuel_lb() + (0.1 if k == "+" else -0.1) * cap)
        elif k == "f":
            err = s.fill_ferry(10_000)
            if err:
                s.say(err)
        super().key(k)

    def refresh(self):
        s = self.s
        lo = s.loadout
        lo.fuel_lb = s.fm.fuel_lb()
        wb = lo.compute()
        zfw = lo.compute(fuel_lb=0.0)
        self.header.setText(f"LOAD PLANNER - {s.spec.name}")
        items = self.rows()
        self.sel = min(self.sel, max(0, len(items) - 1))
        weights = lo.station_weights(planned=True)
        lines = [f"Stations (crew loading: {s.crew_count()}):"]
        for i, st in enumerate(lo.spec.stations):
            who = [it.label for it in lo.items.values() if lo.assignment.get(it.id) == i]
            if st.kind == "pilot":
                who = [f"You ({PILOT_LB:.0f} lb)"]
            elif lo.copilot_aboard and i == lo.copilot_station():
                who = [f"Co-pilot ({PILOT_LB:.0f} lb)"] + who
            over = "  OVER!" if weights[i] > st.max_lb else ""
            lines.append(f"  {st.name:<16} arm {st.x_in:6.1f}  {weights[i]:5.0f}/{st.max_lb:.0f} lb  {', '.join(who)}{over}")
        lines.append("")
        lines.append("Items (LEFT/RIGHT to move between stations):")
        for i, it in enumerate(items):
            st = lo.assignment.get(it.id)
            where = lo.spec.stations[st].name if st is not None else "** ON THE RAMP **"
            cur = ">" if i == self.sel else " "
            flags = ("HOT " if it.hot else "") + ("FRAGILE " if it.fragile else "") + ("DROP " if it.droppable else "")
            if it.kind == "tank":
                flags += f"{it.fuel_lb:.0f}/{it.fuel_cap_lb:.0f} lb fuel "
            pend = f"  (loading {lo.pending[it.id]:.0f}s)" if it.id in lo.pending else ""
            lines.append(f"{cur} {it.label:<16} {it.weight_lb:5.0f} lb  {flags}-> {where}{pend}")
        self.body.setText("\n".join(lines))
        verdict = "OK" if wb.ok else "OUT OF LIMITS"
        details = []
        if wb.overweight_lb > 0:
            details.append(f"{wb.overweight_lb:.0f} lb over MTOW")
        if not wb.in_envelope:
            details.append("CG outside envelope")
        if wb.station_overloads:
            details.append("station overload")
        if lo.unassigned():
            details.append(f"{len(lo.unassigned())} item(s) left on ramp")
        self.footer.setText(
            f"TOW {wb.weight_lb:.0f}/{lo.spec.mtow_lb:.0f} lb   CG {wb.cg_in:.1f} in "
            f"(limits {wb.fwd_limit_in:.1f}-{wb.aft_limit_in:.1f})   fuel {lo.fuel_lb:.0f}/{lo.mass.fuel_capacity_lb:.0f} lb   "
            f"[{verdict}] {'; '.join(details)}\n"
            f"+/- fuel (${FUEL_PRICE_PER_LB:.2f}/lb)  F fill ferry tank  A loadmaster (${LOADMASTER_FEE})  UP/DOWN item  ESC close"
        )
        self._chart(wb, zfw)

    def _chart(self, wb, zfw):
        """CG envelope: x = CG arm, y = weight. Dot = take-off, ring = zero fuel."""
        self.extra.removeNode()
        self.extra = self.frame.attachNewNode("chart")
        env = self.s.spec.envelope
        xs = [p[0] for p in env] + [wb.cg_in, zfw.cg_in]
        ys = [p[1] for p in env] + [wb.weight_lb, zfw.weight_lb]
        x0, x1 = min(xs) - 2, max(xs) + 2
        y0, y1 = min(ys) - 150, max(ys) + 150
        ox, oy, W, H = 0.45, -0.62, 0.72, 0.55

        def P(cg, w):
            return ox + (cg - x0) / (x1 - x0) * W, 0, oy + (w - y0) / (y1 - y0) * H

        ls = LineSegs()
        ls.setThickness(2)
        ls.setColor(0.4, 0.4, 0.4, 1)
        for a, b in (((x0, y0), (x1, y0)), ((x0, y0), (x0, y1))):
            ls.moveTo(*P(*a))
            ls.drawTo(*P(*b))
        ls.setColor(0.3, 1, 0.4, 1)
        ls.moveTo(*P(*env[-1]))
        for p in env:
            ls.drawTo(*P(*p))
        ls.setColor(1, 0.4, 0.3, 1)
        ls.moveTo(*P(x0, self.s.spec.mtow_lb))
        ls.drawTo(*P(x1, self.s.spec.mtow_lb))
        ls.setColor(0.6, 0.6, 1, 1)
        ls.moveTo(*P(zfw.cg_in, zfw.weight_lb))
        ls.drawTo(*P(wb.cg_in, wb.weight_lb))
        self.extra.attachNewNode(ls.create())
        dot = LineSegs()
        dot.setThickness(12)
        dot.setColor(*(GREEN if wb.ok else RED))
        dot.moveTo(*P(wb.cg_in, wb.weight_lb))
        dot.drawTo(*P(wb.cg_in, wb.weight_lb))
        dot.setThickness(7)
        dot.setColor(0.6, 0.6, 1, 1)
        dot.moveTo(*P(zfw.cg_in, zfw.weight_lb))
        dot.drawTo(*P(zfw.cg_in, zfw.weight_lb))
        self.extra.attachNewNode(dot.create())
        OnscreenText(f"CG envelope ({x0:.0f}-{x1:.0f} in)  green=limits red=MTOW  dot=TOW ring=ZFW",
                         parent=self.extra, pos=(ox, oy - 0.05), scale=0.03, fg=(0.8, 0.8, 0.8, 1), align=TextNode.ALeft)


class HangarMenu(Menu):
    """Aircraft dealer, gear shop and services (spotters, crew)."""

    def rows(self):
        s = self.s
        rows = [("aircraft", a) for a in ROSTER.values()]
        rows += [("gear", name) for name in GEAR if {"ferry_tank": "ferry"}.get(name, name) in s.features]
        if "spotters" in s.features:
            rows.append(("spotter", s.location))
        if "copilot" in s.features:
            rows.append(("copilot", None))
        return rows

    def key(self, k):
        if k == "enter":
            rows = self.rows()
            kind, what = rows[min(self.sel, len(rows) - 1)]
            s = self.s
            if kind == "aircraft":
                err = s.buy_or_switch(what.key)
            elif kind == "gear":
                err = s.buy_gear(what)
            elif kind == "spotter":
                err = s.hire_spotter(what)
            else:
                if s.copilot == "human":
                    err = "Your co-pilot is a real person - ask them."
                else:
                    s.set_copilot(None if s.copilot else "ai")
                    err = None
                    s.say("Co-pilot aboard." if s.copilot else "Co-pilot stays on the ground.")
            if err:
                s.say(err)
        super().key(k)

    def refresh(self):
        s = self.s
        self.header.setText("HANGAR, GEAR & SERVICES")
        lines = []
        rows = self.rows()
        self.sel = min(self.sel, max(0, len(rows) - 1))
        for i, (kind, what) in enumerate(rows):
            cur = ">" if i == self.sel else " "
            if kind == "aircraft":
                a = what
                owned = "OWNED" if a.key in s.owned else f"${a.price:,}"
                flying = " (current)" if a.key == s.aircraft_key else ""
                seats = sum(1 for st in a.stations if st.kind == "seat")
                lines.append(f"{cur} {a.name:<24} {owned:>10}{flying}   MTOW {a.mtow_lb:.0f} lb, {seats} seats,"
                             f" roll ~{a.ground_roll_m:.0f} m")
            elif kind == "gear":
                price, desc = GEAR[what]
                have = what in s.gear or (what == "ferry_tank" and any(i.kind == "tank" for i in s.loadout.items.values()))
                lines.append(f"{cur} {desc:<52} {'FITTED' if have else f'${price:,}':>8}")
            elif kind == "spotter":
                watching = ", ".join(sp.code for sp in s.spotters) or "none"
                lines.append(f"{cur} Hire a spotter to watch this strip ($400)   [watching: {watching}]")
            else:
                who = {"human": "human (online)", "ai": "Rosa (AI)", None: "none"}[s.copilot]
                lines.append(f"{cur} Co-pilot: {who}  - loads 2x faster, kicks bales, pumps ferry fuel. ENTER toggles.")
        self.body.setText("\n".join(lines))
        shop = s.airfield.shop if s.airfield else False
        self.footer.setText(("ENTER buy / hire / toggle   " if shop else "No aircraft dealer here (gear and services OK).   ")
                            + "ESC close")


HELP_TEXT = """SKYRUNNER - controls

Flight   W/S or UP/DOWN pitch     A/D or LEFT/RIGHT roll     Q/E rudder / nosewheel
         R/F or PGUP/PGDN throttle   X cut throttle   Z full throttle
         G flaps down   T flaps up   [ / ] pitch trim   B or SPACE brakes
         Y toggle mouse yoke (mouse position = stick)
View     C cycle camera (chase / cockpit / tower)    M big map    P pause
Ground   J job board   L load planner & fuel (F fills the ferry tank)   H hangar, gear, spotters, crew
Crew     N transponder on/off   U autopilot (hold alt/hdg)   K kick a bale   O call the boat
         V ferry fuel pump   I push aircraft round (stopped)   ENTER continue   ESC close menu / quit

Goal: haul passengers & cargo between strips for money. Balance the load:
too heavy = long roll & weak climb, CG too far aft = pitch-up / stall,
too far forward = can't flare. Short strips pay more.
Hot jobs pay big. Squawking looks legit; flying dark (transponder off) is
invisible only below the radar floor - and a squawk that vanishes on radar
is a red flag. Airdrops: fly low and slow over the boat, K to kick
(solo: autopilot first). Police within 350 m for a few seconds = busted.
"""
