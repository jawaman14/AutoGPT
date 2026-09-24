"""Procedural geometry: terrain, water, runways, trees, aircraft and pursuers.

No external art assets: everything is built from vertex-coloured primitives so
the game runs from a clean checkout. Swap in glTF models later via
`loader.loadModel` if you want real art (panda3d-gltf).
"""
from __future__ import annotations

import math

import numpy as np
from panda3d.core import (
    Geom,
    GeomEnums,
    GeomNode,
    GeomTriangles,
    GeomVertexArrayFormat,
    GeomVertexData,
    GeomVertexFormat,
    InternalName,
    NodePath,
    PNMImage,
    Texture,
    TransparencyAttrib,
)

from ..aircraft import Visual
from ..world import CELL, GRID, HALF, World

_FMT = None


def _format() -> GeomVertexFormat:
    global _FMT
    if _FMT is None:
        arr = GeomVertexArrayFormat()
        arr.addColumn(InternalName.getVertex(), 3, GeomEnums.NT_float32, GeomEnums.C_point)
        arr.addColumn(InternalName.getNormal(), 3, GeomEnums.NT_float32, GeomEnums.C_normal)
        arr.addColumn(InternalName.getColor(), 4, GeomEnums.NT_float32, GeomEnums.C_color)
        _FMT = GeomVertexFormat.registerFormat(GeomVertexFormat(arr))
    return _FMT


def mesh_from_arrays(name: str, verts: np.ndarray, normals: np.ndarray, colors: np.ndarray, tris: np.ndarray) -> GeomNode:
    """verts/normals (N,3), colors (N,4) floats; tris (M,3) ints."""
    n = len(verts)
    data = np.empty((n, 10), dtype=np.float32)
    data[:, 0:3] = verts
    data[:, 3:6] = normals
    data[:, 6:10] = colors
    vdata = GeomVertexData(name, _format(), Geom.UHStatic)
    vdata.uncleanSetNumRows(n)
    vdata.modifyArray(0).modifyHandle().copyDataFrom(data.tobytes())
    prim = GeomTriangles(Geom.UHStatic)
    prim.setIndexType(GeomEnums.NT_uint32)
    idx = np.ascontiguousarray(tris, dtype=np.uint32).reshape(-1)
    handle = prim.modifyVertices()
    handle.uncleanSetNumRows(len(idx))
    handle.modifyHandle().copyDataFrom(idx.tobytes())
    geom = Geom(vdata)
    geom.addPrimitive(prim)
    node = GeomNode(name)
    node.addGeom(geom)
    return node


class MeshBuilder:
    """Accumulates flat-shaded quads/triangles, then emits one GeomNode."""

    def __init__(self):
        self.v: list = []
        self.n: list = []
        self.c: list = []
        self.t: list = []

    def tri(self, a, b, c, color):
        a, b, c = np.asarray(a, float), np.asarray(b, float), np.asarray(c, float)
        nrm = np.cross(b - a, c - a)
        ln = np.linalg.norm(nrm)
        nrm = nrm / ln if ln > 1e-9 else np.array([0, 0, 1.0])
        base = len(self.v)
        col = tuple(color) + ((1.0,) if len(color) == 3 else ())
        for p in (a, b, c):
            self.v.append(p)
            self.n.append(nrm)
            self.c.append(col)
        self.t.append((base, base + 1, base + 2))

    def quad(self, a, b, c, d, color):
        self.tri(a, b, c, color)
        self.tri(a, c, d, color)

    def hexa(self, corners, color):
        """8 corners: bottom (-x-y, +x-y, +x+y, -x+y) then top in the same order."""
        p = corners
        self.quad(p[0], p[3], p[2], p[1], color)  # bottom
        self.quad(p[4], p[5], p[6], p[7], color)  # top
        self.quad(p[0], p[1], p[5], p[4], color)  # -y
        self.quad(p[1], p[2], p[6], p[5], color)  # +x
        self.quad(p[2], p[3], p[7], p[6], color)  # +y
        self.quad(p[3], p[0], p[4], p[7], color)  # -x

    def box(self, cx, cy, cz, sx, sy, sz, color):
        hx, hy, hz = sx / 2, sy / 2, sz / 2
        self.frustum(cy - hy, cy + hy, (cx, cz, hx, hz), (cx, cz, hx, hz), color)

    def frustum(self, y0, y1, sec0, sec1, color):
        """Box-like section along Y from y0 to y1; each section = (cx, cz, half_w, half_h)."""
        (x0, z0, w0, h0), (x1, z1, w1, h1) = sec0, sec1
        self.hexa(
            [
                (x0 - w0, y0, z0 - h0), (x0 + w0, y0, z0 - h0), (x1 + w1, y1, z1 - h1), (x1 - w1, y1, z1 - h1),
                (x0 - w0, y0, z0 + h0), (x0 + w0, y0, z0 + h0), (x1 + w1, y1, z1 + h1), (x1 - w1, y1, z1 + h1),
            ],
            color,
        )

    def cone(self, x, y, z0, radius, height, color, segments=6):
        top = (x, y, z0 + height)
        for k in range(segments):
            a0 = 2 * math.pi * k / segments
            a1 = 2 * math.pi * (k + 1) / segments
            self.tri((x + radius * math.cos(a0), y + radius * math.sin(a0), z0),
                     (x + radius * math.cos(a1), y + radius * math.sin(a1), z0), top, color)

    def cylinder(self, x, y, z0, radius, height, color, segments=10):
        for k in range(segments):
            a0 = 2 * math.pi * k / segments
            a1 = 2 * math.pi * (k + 1) / segments
            p0 = (x + radius * math.cos(a0), y + radius * math.sin(a0))
            p1 = (x + radius * math.cos(a1), y + radius * math.sin(a1))
            self.quad((*p0, z0), (*p1, z0), (*p1, z0 + height), (*p0, z0 + height), color)

    def node(self, name="mesh") -> NodePath:
        if not self.v:
            return NodePath(name)
        return NodePath(mesh_from_arrays(name, np.array(self.v), np.array(self.n), np.array(self.c), np.array(self.t)))


# ====================================================================== terrain
def terrain_colors(world: World) -> np.ndarray:
    h = world.heights
    gy, gx = np.gradient(h, CELL)
    slope = np.hypot(gx, gy)
    rng = np.random.default_rng(3)
    jitter = rng.normal(0, 0.025, h.shape)
    grass = np.stack([0.28 + jitter, 0.47 + jitter * 1.5, 0.18 + jitter], -1)
    dry = np.array([0.55, 0.52, 0.30])
    rock = np.array([0.45, 0.42, 0.40])
    sand = np.array([0.83, 0.77, 0.55])
    seabed = np.array([0.55, 0.60, 0.45])
    t_dry = np.clip((h - 250) / 500, 0, 1)[..., None]
    col = grass * (1 - t_dry) + dry * t_dry
    t_rock = np.clip((slope - 0.35) / 0.4, 0, 1)[..., None]
    t_rock = np.maximum(t_rock, np.clip((h - 850) / 250, 0, 1)[..., None])
    col = col * (1 - t_rock) + rock * t_rock
    t_sand = np.clip((6 - h) / 4, 0, 1)[..., None]
    col = col * (1 - t_sand) + sand * t_sand
    col = np.where((h < -2)[..., None], seabed, col)
    return np.clip(col, 0, 1)


def build_terrain(world: World) -> NodePath:
    h = world.heights
    c = np.linspace(-HALF, HALF, GRID)
    X, Y = np.meshgrid(c, c)
    verts = np.stack([X, Y, h], -1).reshape(-1, 3)
    gy, gx = np.gradient(h, CELL)
    normals = np.stack([-gx, -gy, np.ones_like(h)], -1)
    normals /= np.linalg.norm(normals, axis=-1, keepdims=True)
    cols = np.concatenate([terrain_colors(world), np.ones(h.shape + (1,))], -1)
    i = np.arange(GRID - 1)
    ii, jj = np.meshgrid(i, i)
    a = (jj * GRID + ii).reshape(-1)
    b, cc, d = a + 1, a + GRID + 1, a + GRID
    tris = np.concatenate([np.stack([a, b, cc], -1), np.stack([a, cc, d], -1)])
    return NodePath(mesh_from_arrays("terrain", verts, normals.reshape(-1, 3), cols.reshape(-1, 4), tris))


def build_water(size=90_000.0) -> NodePath:
    mb = MeshBuilder()
    s = size / 2
    mb.quad((-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0), (0.12, 0.33, 0.52, 0.88))
    np_ = mb.node("water")
    np_.setTransparency(TransparencyAttrib.MAlpha)
    return np_


def build_trees(world: World) -> NodePath:
    mb = MeshBuilder()
    rng = np.random.default_rng(5)
    for x, y, z, ht in world.trees:
        g = rng.uniform(0.75, 1.1)
        mb.cone(x, y, z + ht * 0.2, ht * 0.28, ht * 0.8, (0.10 * g, 0.28 * g, 0.12 * g), segments=5)
        mb.cone(x, y, z - 0.5, ht * 0.06, ht * 0.25, (0.30, 0.22, 0.12), segments=3)
    return mb.node("trees")


SURFACE_COLORS = {
    "asphalt": (0.20, 0.20, 0.22),
    "gravel": (0.52, 0.49, 0.44),
    "grass": (0.36, 0.55, 0.26),
    "dirt": (0.50, 0.38, 0.25),
    "sand": (0.88, 0.82, 0.62),
}


def build_airfield(world: World, af) -> NodePath:
    mb = MeshBuilder()
    z = world.airfield_elev(af) + 0.12
    ux, uy = af.dir
    px, py = uy, -ux  # right-hand perpendicular

    def p(a, c, dz=0.0):
        return (af.x + ux * a + px * c, af.y + uy * a + py * c, z + dz)

    L, W = af.length / 2, af.width / 2
    mb.quad(p(-L, -W), p(-L, W), p(L, W), p(L, -W), SURFACE_COLORS[af.surface])
    white = (0.95, 0.95, 0.95)
    if af.surface == "asphalt":
        # centreline dashes, threshold bars, aiming blocks
        a = -L + 60
        while a < L - 60:
            mb.quad(p(a, -0.45, 0.02), p(a, 0.45, 0.02), p(a + 30, 0.45, 0.02), p(a + 30, -0.45, 0.02), white)
            a += 50
        for end in (-1, 1):
            for k in range(-4, 5):
                if k == 0:
                    continue
                c0 = k * W / 5.2
                a0 = end * (L - 6)
                a1 = end * (L - 36)
                mb.quad(p(min(a0, a1), c0 - 0.9, 0.02), p(min(a0, a1), c0 + 0.9, 0.02),
                        p(max(a0, a1), c0 + 0.9, 0.02), p(max(a0, a1), c0 - 0.9, 0.02), white)
    # edge markers: white/orange cones every 40 m, big orange boards at the ends
    orange = (1.0, 0.45, 0.05)
    a = -L
    while a <= L + 0.1:
        for side in (-1, 1):
            x, y, _ = p(a, side * (W + 1.5))
            mb.cone(x, y, z, 0.6, 1.0, white if int(a) % 80 else orange, segments=4)
        a += 40
    for end in (-1, 1):
        for side in range(-3, 4):
            x, y, _ = p(end * (L + 3), side * W / 3.5)
            mb.box(x, y, z + 0.4, 1.2, 1.2, 0.8, orange)
    # buildings
    if af.kind in ("hub", "regional"):
        for k, (along, size) in enumerate(((-L * 0.3, 30), (-L * 0.3 + 45, 22), (L * 0.1, 18))):
            x, y, _ = p(along, W + 40 + size / 2)
            mb.box(x, y, z + size * 0.25, size, size * 0.8, size * 0.5, (0.72, 0.72, 0.75) if k else (0.6, 0.62, 0.7))
        tx, ty, _ = p(L * 0.25, W + 55)
        mb.box(tx, ty, z + 10, 5, 5, 20, (0.8, 0.8, 0.8))
        mb.box(tx, ty, z + 21.5, 8, 8, 3, (0.25, 0.4, 0.5))
    else:
        x, y, _ = p(-L * 0.6, W + 18)
        mb.box(x, y, z + 2.5, 9, 7, 5, (0.45, 0.30, 0.18))
    # windsock
    x, y, _ = p(-L * 0.7, -W - 12)
    mb.box(x, y, z + 3, 0.2, 0.2, 6, (0.6, 0.6, 0.6))
    mb.box(x + 1.2, y, z + 5.8, 2.4, 0.5, 0.5, orange)
    node = mb.node(f"af-{af.code}")
    node.setDepthOffset(2)
    return node


def build_beacon(height=260.0, radius=6.0, color=(0.2, 1.0, 0.3, 0.35)) -> NodePath:
    mb = MeshBuilder()
    mb.cylinder(0, 0, 0, radius, height, color, segments=12)
    np_ = mb.node("beacon")
    np_.setTransparency(TransparencyAttrib.MAlpha)
    np_.setTwoSided(True)
    np_.setLightOff()
    np_.setBin("fixed", 10)
    np_.setDepthWrite(False)
    return np_


def minimap_texture(world: World, size=256) -> Texture:
    col = terrain_colors(world)
    h = world.heights
    img = PNMImage(size, size)
    idx = np.linspace(0, GRID - 1, size).astype(int)
    for py_ in range(size):
        row = idx[size - 1 - py_]
        for px_ in range(size):
            c = idx[px_]
            if h[row, c] < 0:
                img.setXel(px_, py_, 0.12, 0.3, 0.5)
            else:
                r, g, b = col[row, c]
                shade = 0.85 + 0.15 * min(1.0, h[row, c] / 900)
                img.setXel(px_, py_, r * shade, g * shade, b * shade)
    tex = Texture("minimap")
    tex.load(img)
    return tex


# ====================================================================== aircraft
def build_aircraft(v: Visual, gear_height_m: float) -> tuple[NodePath, list[NodePath]]:
    """Origin at the CG, +Y forward, +Z up. Returns (root, spinning props)."""
    root = NodePath("aircraft")
    mb = MeshBuilder()
    L, S = v.length_m, v.span_m
    fw = L * 0.075  # fuselage half width
    fh = L * 0.085  # fuselage half height
    body, stripe = v.color, v.stripe
    glass = (0.2, 0.3, 0.4)
    cz = 0.25  # fuselage centre height relative to the CG
    nose_y = L * 0.38
    tail_y = -L * 0.62
    # fuselage: nose, cabin, tail cone
    mb.frustum(nose_y - L * 0.14, nose_y, (0, cz, fw, fh), (0, cz - 0.05, fw * 0.55, fh * 0.6), body)
    mb.frustum(-L * 0.12, nose_y - L * 0.14, (0, cz, fw, fh), (0, cz, fw, fh), body)
    mb.frustum(tail_y, -L * 0.12, (0, cz + fh * 0.55, fw * 0.18, fh * 0.28), (0, cz, fw, fh), body)
    # windows / windscreen
    mb.frustum(nose_y - L * 0.2, nose_y - L * 0.135, (0, cz + fh * 0.8, fw * 1.01, fh * 0.35), (0, cz + fh * 0.6, fw * 0.85, fh * 0.3), glass)
    mb.box(0, -L * 0.02, cz + fh * 0.45, fw * 2.03, L * 0.14, fh * 0.45, glass)
    # stripe
    mb.box(0, -L * 0.1, cz - fh * 0.2, fw * 2.04, L * 0.55, fh * 0.18, stripe)
    # wings
    chord = S * 0.14
    wz = cz + fh + 0.08 if v.wing == "high" else cz - fh * 0.8
    wy = nose_y - L * 0.3
    mb.box(0, wy, wz, S, chord, 0.16, body)
    mb.box(S * 0.47, wy, wz + 0.01, S * 0.06, chord * 1.01, 0.17, stripe)
    mb.box(-S * 0.47, wy, wz + 0.01, S * 0.06, chord * 1.01, 0.17, stripe)
    if v.wing == "high":
        for side in (-1, 1):  # struts
            mb.frustum(wy - 0.05, wy + 0.05, (side * fw, cz - fh * 0.6, 0.05, 0.05), (side * S * 0.28, wz, 0.05, 0.05), (0.7, 0.7, 0.7))
    # tail
    mb.box(0, tail_y + 0.35, cz + fh * 0.55, S * 0.36, chord * 0.75, 0.1, body)
    mb.frustum(tail_y + 0.05, tail_y + chord * 0.9, (0, cz + fh * 0.55 + L * 0.09, 0.06, L * 0.09), (0, cz + fh * 0.55 + L * 0.05, 0.06, L * 0.05), body)
    mb.box(0, tail_y + 0.4, cz + fh * 0.55 + L * 0.13, 0.13, chord * 0.5, L * 0.05, stripe)
    # engines
    engine_pos = []
    if v.engines == 1:
        engine_pos.append((0.0, nose_y + 0.05, cz - 0.05))
    else:
        for side in (-1, 1):
            ex = side * S * 0.2
            mb.frustum(wy - chord * 0.9, wy + chord * 0.9, (ex, wz - 0.1, 0.32, 0.32), (ex, wz - 0.1, 0.28, 0.3), body)
            engine_pos.append((ex, wy + chord * 0.9 + 0.05, wz - 0.1))
    # gear
    gz = -gear_height_m
    tire = (0.08, 0.08, 0.08)
    main_y = -L * 0.06
    for side in (-1, 1):
        mb.frustum(main_y - 0.06, main_y + 0.06, (side * fw, cz - fh, 0.05, 0.05), (side * fw * 2.2, gz + 0.3, 0.05, 0.05), (0.6, 0.6, 0.6))
        mb.box(side * fw * 2.2, main_y, gz + 0.3, 0.18, 0.6, 0.6, tire)
    if v.tricycle:
        mb.box(0, nose_y - L * 0.08, (cz + gz) / 2, 0.08, 0.08, cz - gz - 0.3, (0.6, 0.6, 0.6))
        mb.box(0, nose_y - L * 0.08, gz + 0.25, 0.14, 0.5, 0.5, tire)
    mb.node("airframe").reparentTo(root)
    props = []
    for ex, ey, ez in engine_pos:
        pm = MeshBuilder()
        r = 0.95 if v.engines == 1 else 1.2
        pm.box(0, 0, 0, r * 2, 0.06, 0.14, (0.12, 0.12, 0.12))
        pm.box(0, 0.06, 0, 0.25, 0.2, 0.25, (0.8, 0.8, 0.8))
        prop = pm.node("prop")
        prop.reparentTo(root)
        prop.setPos(ex, ey, ez)
        props.append(prop)
    return root, props


def build_pursuer(kind: str) -> tuple[NodePath, list[NodePath], list[NodePath]]:
    """Returns (root, rotors/props, light-bar nodes)."""
    root = NodePath(kind)
    lights: list[NodePath] = []
    spinners: list[NodePath] = []
    if kind == "heli":
        mb = MeshBuilder()
        blue, white = (0.08, 0.15, 0.55), (0.93, 0.93, 0.95)
        mb.frustum(-1.5, 2.2, (0, 0, 1.0, 1.1), (0, -0.1, 0.7, 0.8), white)
        mb.frustum(2.2, 3.0, (0, -0.1, 0.7, 0.8), (0, -0.3, 0.2, 0.3), (0.2, 0.3, 0.4))
        mb.box(0, 0.3, -0.4, 2.02, 3.6, 0.35, blue)
        mb.frustum(-7.5, -1.5, (0, 0.4, 0.15, 0.2), (0, 0.2, 0.45, 0.5), blue)
        mb.box(0, -7.3, 1.1, 0.1, 0.8, 1.6, blue)
        for side in (-1, 1):
            mb.box(side * 1.1, 0, -1.6, 0.12, 4.0, 0.12, (0.2, 0.2, 0.2))
        mb.box(0, 0, 1.3, 0.3, 0.3, 0.5, (0.3, 0.3, 0.3))
        mb.node("heli").reparentTo(root)
        rm = MeshBuilder()
        rm.box(0, 0, 0, 10.5, 0.35, 0.06, (0.1, 0.1, 0.1))
        rm.box(0, 0, 0, 0.35, 10.5, 0.06, (0.1, 0.1, 0.1))
        rotor = rm.node("rotor")
        rotor.reparentTo(root)
        rotor.setZ(1.6)
        spinners.append(rotor)
        bar_z, bar_y = 1.15, 1.0
    elif kind == "interceptor":
        mb = MeshBuilder()
        body, dark = (0.12, 0.16, 0.3), (0.05, 0.05, 0.08)
        mb.frustum(-6, 4, (0, 0, 0.8, 0.8), (0, 0, 0.6, 0.6), body)
        mb.frustum(4, 8, (0, 0, 0.6, 0.6), (0, -0.1, 0.05, 0.05), body)
        mb.frustum(1.5, 4.5, (0, 0.7, 0.45, 0.25), (0, 0.6, 0.2, 0.1), (0.3, 0.4, 0.5))
        for side in (-1, 1):
            mb.tri((side * 0.6, 2.5, 0), (side * 5.5, -3.5, 0), (side * 0.6, -4.5, 0), body)
            mb.tri((side * 0.6, 2.5, 0), (side * 0.6, -4.5, 0), (side * 5.5, -3.5, 0), body)
        mb.frustum(-6, -2.5, (0, 1.9, 0.08, 1.2), (0, 0.9, 0.08, 0.2), dark)
        mb.box(0, -3.0, 0.02, 7, 1.8, 0.08, (0.9, 0.9, 0.9))
        mb.node("jet").reparentTo(root)
        bar_z, bar_y = 0.95, 0.0
    else:  # rival smugglers: a black twin
        v = Visual("low", 2, 11.0, 12.5, (0.07, 0.07, 0.07), (0.6, 0.1, 0.6))
        root, spinners = build_aircraft(v, 1.2)
        return root, spinners, []
    for k, (x, col) in enumerate(((-0.35, (1, 0.05, 0.05)), (0.35, (0.1, 0.3, 1)))):
        lm = MeshBuilder()
        lm.box(0, 0, 0, 0.5, 0.3, 0.2, col)
        ln = lm.node(f"light{k}")
        ln.reparentTo(root)
        ln.setPos(x, bar_y, bar_z)
        ln.setLightOff()
        lights.append(ln)
    return root, spinners, lights


# ====================================================================== maritime
def build_boat(kind: str) -> tuple[NodePath, list[NodePath]]:
    """Go-fast (long, low, loud) or Coast Guard cutter. +Y forward, waterline at z=0."""
    mb = MeshBuilder()
    lights: list[NodePath] = []
    if kind == "cutter":
        hull, trim = (0.92, 0.92, 0.94), (0.8, 0.15, 0.1)
        mb.frustum(-18, 14, (0, 0.8, 3.2, 1.6), (0, 1.2, 2.6, 1.8), hull)
        mb.frustum(14, 22, (0, 1.2, 2.6, 1.8), (0, 2.0, 0.2, 0.9), hull)
        mb.box(0, 8, 1.2, 5.3, 1.2, 1.5, trim)  # racing stripe
        mb.box(0, -2, 4.4, 4.2, 10, 3.0, hull)  # superstructure
        mb.box(0, 1, 7.0, 2.2, 3, 2.2, (0.3, 0.35, 0.4))
        mb.box(0, -1, 9.5, 0.3, 0.3, 3.0, (0.2, 0.2, 0.2))  # mast
        root = mb.node("cutter")
        lm = MeshBuilder()
        lm.box(0, 0, 0, 0.8, 0.8, 0.5, (0.2, 0.4, 1))
        light = lm.node("beacon")
        light.reparentTo(root)
        light.setPos(0, -1, 11.2)
        light.setLightOff()
        lights.append(light)
    else:
        hull, deck = (0.95, 0.95, 0.95), (0.85, 0.1, 0.25)
        mb.frustum(-5.5, 5, (0, 0.3, 1.2, 0.6), (0, 0.45, 1.0, 0.6), hull)
        mb.frustum(5, 8, (0, 0.45, 1.0, 0.6), (0, 0.8, 0.1, 0.25), hull)
        mb.box(0, 0, 1.0, 2.05, 9.5, 0.12, deck)
        mb.box(0, 0.5, 1.4, 1.6, 1.4, 0.8, (0.15, 0.2, 0.25))  # windscreen
        for side in (-0.45, 0.45):
            mb.box(side, -5.9, 0.2, 0.35, 0.6, 1.0, (0.1, 0.1, 0.1))  # outboards
        root = mb.node("gofast")
    return root, lights


def build_bale() -> NodePath:
    mb = MeshBuilder()
    mb.box(0, 0, 0.3, 0.9, 0.6, 0.6, (0.55, 0.45, 0.25))
    mb.box(0, 0, 0.3, 0.92, 0.1, 0.62, (0.2, 0.2, 0.2))
    return mb.node("bale")


def build_aerostat() -> NodePath:
    """Tethered radar balloon: a fat white ellipsoid with fins, radome underneath."""
    mb = MeshBuilder()
    segs, rings = 16, 10
    L, R = 70.0, 13.0
    pts = []
    for r in range(rings + 1):
        t = r / rings
        y = -L / 2 + t * L
        rad = R * math.sin(math.pi * t) ** 0.7
        pts.append([(rad * math.cos(2 * math.pi * k / segs), y, rad * math.sin(2 * math.pi * k / segs))
                    for k in range(segs)])
    white = (0.95, 0.95, 0.93)
    for r in range(rings):
        for k in range(segs):
            a, b = pts[r][k], pts[r][(k + 1) % segs]
            c, d = pts[r + 1][(k + 1) % segs], pts[r + 1][k]
            mb.quad(a, d, c, b, white)
    for ang in (0, 120, 240):
        a = math.radians(ang + 90)
        tip = (math.cos(a) * R * 1.3, -L * 0.42, math.sin(a) * R * 1.3)
        mb.tri((0, -L * 0.3, 0), (0, -L * 0.48, 0), tip, (0.85, 0.85, 0.85))
        mb.tri((0, -L * 0.48, 0), (0, -L * 0.3, 0), tip, (0.85, 0.85, 0.85))
    mb.box(0, 0, -R - 2.5, 7, 7, 5, (0.8, 0.8, 0.8))  # radome
    return mb.node("aerostat")
