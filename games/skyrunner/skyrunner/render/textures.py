"""Procedural textures, generated with numpy at start-up (no asset files).

  terrain_texture   the whole island baked into one image: the height/slope
                    colour ramp, hill-shading from the sun, and noise
  detail_texture    a small tiling grain multiplied over the terrain up close
  surface_texture   runway surfaces: asphalt, gravel, grass (mowing stripes),
                    dirt (wheel ruts), sand
  water_texture     tiling ripples, scrolled every frame on medium/high
"""
from __future__ import annotations

import numpy as np
from panda3d.core import SamplerState, Texture

from ..world import CELL, GRID


def to_texture(rgb: np.ndarray, name: str, repeat: bool = False, mipmap: bool = True) -> Texture:
    """rgb: (H, W, 3|4) floats 0..1, row 0 = bottom (v = 0)."""
    img = np.clip(rgb * 255.0, 0, 255).astype(np.uint8)
    h, w, ch = img.shape
    tex = Texture(name)
    tex.setup2dTexture(w, h, Texture.T_unsigned_byte, Texture.F_rgba if ch == 4 else Texture.F_rgb)
    tex.setRamImageAs(np.ascontiguousarray(img).tobytes(), "RGBA" if ch == 4 else "RGB")
    wrap = SamplerState.WM_repeat if repeat else SamplerState.WM_clamp
    tex.setWrapU(wrap)
    tex.setWrapV(wrap)
    tex.setMinfilter(SamplerState.FT_linear_mipmap_linear if mipmap else SamplerState.FT_linear)
    tex.setMagfilter(SamplerState.FT_linear)
    tex.setAnisotropicDegree(4)
    return tex


def _value_noise(size: int, cells: int, rng: np.random.Generator) -> np.ndarray:
    """Tileable smooth noise, 0..1."""
    g = rng.random((cells, cells))
    t = np.arange(size) / size * cells
    i0 = np.floor(t).astype(int) % cells
    i1 = (i0 + 1) % cells
    f = t - np.floor(t)
    f = f * f * (3 - 2 * f)
    a = g[np.ix_(i0, i0)] * (1 - f)[None, :] + g[np.ix_(i0, i1)] * f[None, :]
    b = g[np.ix_(i1, i0)] * (1 - f)[None, :] + g[np.ix_(i1, i1)] * f[None, :]
    return a * (1 - f)[:, None] + b * f[:, None]


def fbm(size: int, base: int = 4, octaves: int = 5, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    out = np.zeros((size, size))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        cells = base * 2 ** o
        if cells > size:
            break
        out += _value_noise(size, cells, rng) * amp
        tot += amp
        amp *= 0.5
    return out / tot


def _upsample(a: np.ndarray, size: int) -> np.ndarray:
    """Bilinear resample of a (GRID, GRID[, C]) array to (size, size[, C])."""
    n = a.shape[0]
    t = np.linspace(0, n - 1, size)
    i0 = np.clip(np.floor(t).astype(int), 0, n - 2)
    f = t - i0
    if a.ndim == 2:
        a = a[..., None]
    rows = a[i0] * (1 - f)[:, None, None] + a[i0 + 1] * f[:, None, None]
    out = rows[:, i0] * (1 - f)[None, :, None] + rows[:, i0 + 1] * f[None, :, None]
    return out


def terrain_texture(world, colors: np.ndarray, size: int = 2048) -> Texture:
    """Island colour map with baked hill-shading. Row 0 = south (y = -HALF)."""
    h = world.heights
    gy, gx = np.gradient(h, CELL)
    n = np.stack([-gx, -gy, np.ones_like(h)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    sun = np.array([0.45, 0.35, 0.82])
    sun /= np.linalg.norm(sun)
    shade = np.clip(n @ sun, 0.0, 1.0)
    # the colour ramp carries per-cell jitter; blur it so 62 m cells don't show as squares up close
    pad = np.pad(colors, ((1, 1), (1, 1), (0, 0)), mode="edge")
    smooth = sum(pad[1 + dj:1 + dj + colors.shape[0], 1 + di:1 + di + colors.shape[1]]
                 for dj in (-1, 0, 1) for di in (-1, 0, 1)) / 9.0
    col = _upsample(smooth, size)
    sh = _upsample(shade, size)[..., 0]
    hh = _upsample(h, size)[..., 0]
    grain = fbm(size, base=64, octaves=4, seed=11)
    blotch = fbm(size, base=12, octaves=4, seed=12)
    col = col * (0.82 + 0.28 * grain[..., None]) * (0.9 + 0.2 * blotch[..., None])
    col = col * (0.62 + 0.5 * sh[..., None])
    # surf line: a pale fringe where land meets the sea
    surf = np.clip(1 - np.abs(hh - 0.5) / 2.0, 0, 1)[..., None] * (hh > -2)[..., None]
    col = col * (1 - 0.5 * surf) + np.array([0.93, 0.92, 0.86]) * 0.5 * surf
    return to_texture(np.clip(col, 0, 1), "terrain")


def detail_texture(size: int = 256) -> Texture:
    g = fbm(size, base=8, octaves=5, seed=21)
    g = 0.78 + 0.44 * g
    return to_texture(np.repeat(g[..., None], 3, -1), "detail", repeat=True)


_SURF = {
    "asphalt": ((0.22, 0.22, 0.24), 0.10),
    "gravel": ((0.55, 0.52, 0.47), 0.22),
    "grass": ((0.36, 0.55, 0.26), 0.16),
    "dirt": ((0.52, 0.40, 0.27), 0.20),
    "sand": ((0.88, 0.82, 0.63), 0.10),
}


def surface_texture(surface: str, size: int = 256) -> Texture:
    base, var = _SURF[surface]
    rng = np.random.default_rng(hash(surface) % 1000)
    fine = rng.random((size, size))
    coarse = fbm(size, base=8, octaves=4, seed=hash(surface) % 97)
    g = 1 - var + 2 * var * (0.6 * coarse + 0.4 * fine)
    col = np.array(base)[None, None, :] * g[..., None]
    v = np.arange(size) / size  # along the runway
    u = np.arange(size) / size  # across
    if surface == "grass":  # mowing stripes along the strip
        stripes = (np.floor(u * 4) % 2)[None, :] * 0.08
        col *= (1 - stripes)[..., None] + 0.04
    elif surface == "dirt":  # two wheel ruts
        ruts = np.exp(-((u - 0.35) / 0.04) ** 2) + np.exp(-((u - 0.65) / 0.04) ** 2)
        col *= (1 - 0.18 * ruts)[None, :, None]
    elif surface == "asphalt":  # patching and tyre marks near the ends
        marks = (rng.random((size, size)) < 0.002).astype(float)
        col *= 1 - 0.3 * marks[..., None]
        tyre = np.exp(-((u - 0.5) / 0.12) ** 2)[None, :] * (np.abs(v - 0.5) > 0.3)[:, None]
        col *= 1 - 0.15 * tyre[..., None]
    return to_texture(np.clip(col, 0, 1), f"surf-{surface}", repeat=True)


def water_texture(size: int = 256) -> Texture:
    a = fbm(size, base=8, octaves=5, seed=31)
    b = fbm(size, base=16, octaves=4, seed=32)
    w = 0.5 * a + 0.5 * b
    deep = np.array([0.08, 0.27, 0.45])
    light = np.array([0.22, 0.48, 0.62])
    col = deep + (light - deep) * w[..., None] ** 1.5
    spark = (w > 0.78)[..., None] * 0.25
    rgba = np.concatenate([np.clip(col + spark, 0, 1), np.full((size, size, 1), 0.86)], -1)
    return to_texture(rgba, "water", repeat=True)


def sky_colors(z: np.ndarray) -> np.ndarray:
    """Vertex colours for the sky dome by height fraction 0 (horizon) .. 1 (zenith)."""
    horizon = np.array([0.78, 0.86, 0.93])
    zenith = np.array([0.23, 0.45, 0.78])
    t = np.clip(z, 0, 1) ** 0.6
    return horizon[None, :] * (1 - t)[:, None] + zenith[None, :] * t[:, None]


__all__ = ["to_texture", "fbm", "terrain_texture", "detail_texture", "surface_texture", "water_texture",
           "sky_colors", "GRID"]
