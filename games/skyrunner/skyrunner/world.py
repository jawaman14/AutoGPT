"""Procedural island, airfields, obstacles and terrain queries.

Everything is deterministic from a seed so the renderer, physics and tests all
see the same world. Heights are stored on a regular grid and sampled
bilinearly; JSBSim is fed the height under the aircraft every physics step.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

SIZE_M = 32_000.0  # play area is [-SIZE/2, SIZE/2]^2
GRID = 513
CELL = SIZE_M / (GRID - 1)
HALF = SIZE_M / 2


@dataclass(frozen=True)
class Airfield:
    code: str
    name: str
    x: float
    y: float
    heading: float  # runway direction, deg true
    length: float  # m
    width: float  # m
    elev: float | None  # None -> take natural terrain height at the centre
    surface: str  # asphalt | gravel | grass | dirt | sand
    kind: str  # hub | regional | bush | shady
    shop: bool = False
    police: bool = False  # police presence: inspections when wanted
    radar_km: float = 0.0
    setting: str = "flat"  # flat | plateau | pit | beach
    tree_lines: bool = False

    @property
    def dir(self) -> tuple[float, float]:
        h = math.radians(self.heading)
        return math.sin(h), math.cos(h)

    def to_local(self, x: float, y: float) -> tuple[float, float]:
        """(along, across) in runway coordinates, origin at the centre."""
        dx, dy = x - self.x, y - self.y
        ux, uy = self.dir
        return dx * ux + dy * uy, dx * uy - dy * ux

    def contains(self, x: float, y: float, margin: float = 0.0) -> bool:
        a, c = self.to_local(x, y)
        return abs(a) <= self.length / 2 + margin and abs(c) <= self.width / 2 + margin

    def threshold(self, end: int) -> tuple[float, float]:
        """World position of runway end 0 (start of heading) or 1."""
        ux, uy = self.dir
        s = -1 if end == 0 else 1
        return self.x + s * ux * self.length / 2, self.y + s * uy * self.length / 2

    @property
    def is_short(self) -> bool:
        return self.length < 500


AIRFIELDS: tuple[Airfield, ...] = (
    Airfield("HAR", "Port Harbor Intl", -9000, -9500, 70, 1800, 45, 8, "asphalt", "hub",
             shop=True, police=True, radar_km=22),
    Airfield("VAL", "Valley Regional", 2500, -3000, 20, 1000, 30, None, "asphalt", "regional",
             shop=True, police=True, radar_km=12),
    Airfield("FRM", "Miller's Farm", -6500, -1500, 110, 480, 20, None, "grass", "bush"),
    Airfield("PNR", "Pine Ridge", 10000, 8500, 225, 380, 15, None, "gravel", "bush",
             tree_lines=True),
    Airfield("EGL", "Eagle's Nest", 1000, 9000, 250, 280, 14, 1150, "dirt", "bush",
             setting="plateau"),
    Airfield("COV", "Smuggler's Cove", 11500, -8000, 10, 320, 18, 3, "sand", "shady",
             setting="beach"),
    Airfield("QRY", "Old Quarry", -10000, 5500, 160, 240, 12, None, "dirt", "shady",
             setting="pit"),
    Airfield("ISL", "Isla Verde", 12800, 11500, 300, 550, 20, 12, "grass", "regional"),
)
AIRFIELD_BY_CODE = {a.code: a for a in AIRFIELDS}


def _value_noise(rng: np.random.Generator, n: int, cells: int) -> np.ndarray:
    """Smooth value noise on an n x n grid with `cells` lattice cells."""
    lattice = rng.random((cells + 2, cells + 2))
    t = np.linspace(0, cells, n, endpoint=False)
    i = t.astype(int)
    f = t - i
    f = f * f * (3 - 2 * f)
    a = lattice[i][:, i]
    b = lattice[i][:, i + 1]
    c = lattice[i + 1][:, i]
    d = lattice[i + 1][:, i + 1]
    fx = f[None, :]
    fy = f[:, None]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def _fbm(rng, n, base_cells=4, octaves=6) -> np.ndarray:
    out = np.zeros((n, n))
    amp, total = 1.0, 0.0
    cells = base_cells
    for _ in range(octaves):
        out += amp * _value_noise(rng, n, cells)
        total += amp
        amp *= 0.5
        cells *= 2
    return out / total


def _smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


@dataclass
class World:
    seed: int = 7
    heights: np.ndarray = field(init=False, repr=False)
    trees: np.ndarray = field(init=False, repr=False)  # (N, 4): x, y, base z, height
    airfields: tuple[Airfield, ...] = AIRFIELDS

    def __post_init__(self):
        self.field_elev: dict[str, float] = {}
        self.heights = self._generate_terrain()
        self.trees = self._scatter_trees()
        self._tree_grid = self._bucket_trees()

    # ------------------------------------------------------------ generation
    def grid_xy(self):
        c = np.linspace(-HALF, HALF, GRID)
        return np.meshgrid(c, c)  # X[row, col], Y[row, col]; row = y index

    def _generate_terrain(self) -> np.ndarray:
        rng = np.random.default_rng(self.seed)
        X, Y = self.grid_xy()
        noise = _fbm(rng, GRID, 4, 7)
        noise = (noise - noise.min()) / (noise.max() - noise.min())
        detail = _fbm(rng, GRID, 16, 4)
        detail = (detail - detail.min()) / (detail.max() - detail.min())
        # island mask: squashed radial falloff with a noisy coastline
        r = np.hypot(X / 14500, Y / 13500) + (noise - 0.5) * 0.35
        land = _smoothstep(1.02, 0.72, r)
        # mountain ridge sweeping across the north-centre of the island
        ridge_d = np.abs(Y - (5200 + 2200 * np.sin(X / 6000.0)))
        ridge = np.exp(-(ridge_d / 3000) ** 2) * (0.25 + 0.75 * noise + 0.5 * detail)
        h = land * (35 + 260 * noise + 120 * detail) + land * ridge * 1150
        h = h - (1 - land) * 60  # sea floor
        # guarantee land for offshore strips
        for af in AIRFIELDS:
            bump = np.exp(-(((X - af.x) ** 2 + (Y - af.y) ** 2) / (1400.0 ** 2)))
            amp = 30.0 if af.elev is None else min(30.0, af.elev + 3.0)
            h = np.maximum(h, bump * amp - (1 - bump) * 60)
        for af in AIRFIELDS:
            h = self._shape_airfield(h, X, Y, af)
        return h.astype(np.float32)

    def _shape_airfield(self, h, X, Y, af: Airfield):
        ux, uy = af.dir
        dx, dy = X - af.x, Y - af.y
        along = np.abs(dx * ux + dy * uy) - af.length / 2
        across = np.abs(dx * uy - dy * ux) - af.width / 2
        # rounded-rectangle distance outside the strip (0 inside)
        dist = np.hypot(np.maximum(along, 0), np.maximum(across, 0))
        elev = af.elev if af.elev is not None else float(self._sample(h, af.x, af.y))
        elev = max(elev, 2.0)
        if af.setting == "plateau":
            # flat top, then a cliff falling to the natural terrain
            top = _smoothstep(130, 80, dist)
            h = np.where(dist < 130, h * (1 - top) + elev * top, np.minimum(h, elev - 180 * _smoothstep(130, 260, dist)))
        elif af.setting == "pit":
            # trench cut into the hillside: steep side walls, open at the ends
            flat = _smoothstep(110, 60, dist)
            side = np.exp(-((across - 55) / 30) ** 2) * 70 * _smoothstep(90, 0, along)
            h = h * (1 - flat) + elev * flat + side
        else:
            reach = 650 if af.setting == "beach" else 260
            blend = _smoothstep(reach, 50, dist)
            h = h * (1 - blend) + elev * blend
        self.field_elev[af.code] = elev
        return h

    @staticmethod
    def _sample(h, x, y):
        fx = (x + HALF) / CELL
        fy = (y + HALF) / CELL
        i = int(np.clip(fx, 0, GRID - 2))
        j = int(np.clip(fy, 0, GRID - 2))
        tx, ty = fx - i, fy - j
        return (
            h[j, i] * (1 - tx) * (1 - ty)
            + h[j, i + 1] * tx * (1 - ty)
            + h[j + 1, i] * (1 - tx) * ty
            + h[j + 1, i + 1] * tx * ty
        )

    def _scatter_trees(self) -> np.ndarray:
        rng = np.random.default_rng(self.seed + 1)
        forest = _fbm(rng, GRID, 8, 3)
        pts = []
        cand = rng.uniform(-HALF, HALF, size=(60000, 2))
        for x, y in cand:
            z = self.height(x, y)
            if z < 6 or z > 1300:
                continue
            fi = int((y + HALF) / CELL), int((x + HALF) / CELL)
            if forest[fi] < 0.52:
                continue
            if any(af.contains(x, y, margin=45) for af in self.airfields):
                continue
            pts.append((x, y, z, rng.uniform(9, 20)))
        # deliberate obstacles: tree lines off both ends of bush strips
        for af in self.airfields:
            if not af.tree_lines:
                continue
            ux, uy = af.dir
            for end in (-1, 1):
                d = af.length / 2 + 60
                for k in np.linspace(-45, 45, 13):
                    x = af.x + end * ux * d + uy * k
                    y = af.y + end * uy * d - ux * k
                    pts.append((x, y, self.height(x, y), 22.0))
        return np.array(pts, dtype=np.float32).reshape(-1, 4)

    def _bucket_trees(self, bucket=250.0):
        grid: dict[tuple[int, int], list[int]] = {}
        for i, (x, y, _, _) in enumerate(self.trees):
            grid.setdefault((int(x // bucket), int(y // bucket)), []).append(i)
        self._bucket = bucket
        return grid

    # ------------------------------------------------------------ queries
    def height(self, x: float, y: float) -> float:
        """Terrain height (may be negative: sea floor)."""
        return float(self._sample(self.heights, x, y))

    def ground(self, x: float, y: float) -> float:
        """Surface an aircraft can touch: runway, terrain or sea level."""
        for af in self.airfields:
            if af.contains(x, y, margin=8.0):
                return self.field_elev[af.code]
        return max(self.height(x, y), 0.0)

    def is_water(self, x: float, y: float) -> bool:
        return self.height(x, y) < 0.0

    def airfield_at(self, x: float, y: float, margin: float = 0.0) -> Airfield | None:
        for af in self.airfields:
            if af.contains(x, y, margin):
                return af
        return None

    def airfield_elev(self, af: Airfield) -> float:
        return self.field_elev[af.code]

    def nearest_airfield(self, x: float, y: float) -> tuple[Airfield, float]:
        best = min(self.airfields, key=lambda a: (a.x - x) ** 2 + (a.y - y) ** 2)
        return best, math.hypot(best.x - x, best.y - y)

    def tree_hit(self, x: float, y: float, z: float, radius: float = 5.0) -> bool:
        b = self._bucket
        bi, bj = int(x // b), int(y // b)
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for idx in self._tree_grid.get((bi + di, bj + dj), ()):
                    tx, ty, tz, th = self.trees[idx]
                    if z < tz + th and (tx - x) ** 2 + (ty - y) ** 2 < (radius + th * 0.25) ** 2:
                        return True
        return False

    def heights_many(self, xs: np.ndarray, ys: np.ndarray) -> np.ndarray:
        """Vectorised bilinear terrain height (sea floor included)."""
        fx = np.clip((xs + HALF) / CELL, 0, GRID - 1.0001)
        fy = np.clip((ys + HALF) / CELL, 0, GRID - 1.0001)
        i = fx.astype(int)
        j = fy.astype(int)
        tx, ty = fx - i, fy - j
        h = self.heights
        return (
            h[j, i] * (1 - tx) * (1 - ty)
            + h[j, i + 1] * tx * (1 - ty)
            + h[j + 1, i] * (1 - tx) * ty
            + h[j + 1, i + 1] * tx * ty
        )

    def line_of_sight(self, a: tuple[float, float, float], b: tuple[float, float, float], step: float = 200.0) -> bool:
        ax, ay, az = a
        bx, by, bz = b
        d = math.hypot(bx - ax, by - ay)
        n = max(2, int(d / step))
        t = np.arange(1, n) / n
        ground = np.maximum(self.heights_many(ax + (bx - ax) * t, ay + (by - ay) * t), 0.0)
        return bool(np.all(ground <= az + (bz - az) * t))
