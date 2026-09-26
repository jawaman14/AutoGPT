"""Graphics quality presets.

  low     vertex colours only, half-resolution terrain mesh, a third of the
          trees, no shaders, no textures, no MSAA. For bots you want to
          watch, old laptops, and software rendering (p3tinydisplay).
  medium  procedural textures (terrain, runways, water) and a sky dome,
          fixed-function lighting.
  high    medium + per-pixel lighting, sun shadows on aircraft, scrolling
          water, 4x MSAA.

Headless simulation (`skyrunner.sim`, the tests, dedicated servers) never
touches any of this: it doesn't import Panda3D at all.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Quality:
    name: str
    textures: bool
    terrain_step: int  # 1 = full 513^2 mesh, 2 = 257^2
    terrain_tex: int  # baked terrain texture size (0 = none)
    tree_keep: int  # keep 1 in N trees
    tree_segments: int
    shaders: bool
    shadows: bool
    msaa: int
    sky: bool
    water_anim: bool
    fog_far: float


PRESETS = {
    "low": Quality("low", False, 2, 0, 3, 4, False, False, 0, False, False, 22_000),
    "medium": Quality("medium", True, 1, 2048, 1, 5, False, False, 0, True, True, 30_000),
    "high": Quality("high", True, 1, 4096, 1, 7, True, True, 4, True, True, 34_000),
}


def get(name: str | None) -> Quality:
    return PRESETS.get(name or "high", PRESETS["high"])
