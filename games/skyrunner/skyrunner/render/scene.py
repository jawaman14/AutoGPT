"""The static world scene shared by the pilot's app and the remote 3D seats:
lights, fog, sky, terrain, water, trees and airfields at a quality preset."""
from __future__ import annotations

from dataclasses import dataclass

from panda3d.core import (
    AmbientLight,
    AntialiasAttrib,
    CompassEffect,
    DirectionalLight,
    Fog,
    NodePath,
    TextureStage,
    Vec4,
)

from . import models
from .quality import Quality

SKY = (0.55, 0.72, 0.9, 1)


@dataclass
class WorldScene:
    root: NodePath
    water: NodePath
    sky: NodePath | None
    sun: NodePath
    quality: Quality
    t: float = 0.0

    def update(self, dt: float) -> None:
        """Scroll the water ripples (medium/high)."""
        self.t += dt
        if self.quality.water_anim:
            ts = TextureStage.getDefault()
            self.water.setTexOffset(ts, self.t * 0.004, self.t * 0.0025)


def build_world_scene(base, world, quality: Quality) -> WorldScene:
    render = base.render
    base.setBackgroundColor(*SKY)
    root = render.attachNewNode("world")
    sun = DirectionalLight("sun")
    sun.setColor(Vec4(1.0, 0.96, 0.88, 1))
    sun_np = render.attachNewNode(sun)
    sun_np.setHpr(-35, -50, 0)
    render.setLight(sun_np)
    amb = AmbientLight("amb")
    amb.setColor(Vec4(0.42, 0.45, 0.52, 1) if not quality.shaders else Vec4(0.36, 0.39, 0.46, 1))
    render.setLight(render.attachNewNode(amb))
    fog = Fog("haze")
    fog.setColor(*SKY[:3])
    fog.setLinearRange(quality.fog_far * 0.2, quality.fog_far)
    render.setFog(fog)
    if quality.shaders:
        render.setShaderAuto()
    if quality.msaa:
        render.setAntialias(AntialiasAttrib.MMultisample)
    if quality.shadows:
        sun.setShadowCaster(True, 2048, 2048)
        lens = sun.getLens()
        lens.setFilmSize(120, 120)  # a tight box that follows the camera target
        lens.setNearFar(-400, 400)
    models.build_terrain(world, quality).reparentTo(root)
    water = models.build_water(quality=quality)
    water.reparentTo(root)
    models.build_trees(world, quality).reparentTo(root)
    for af in world.airfields:
        models.build_airfield(world, af, quality).reparentTo(root)
    sky = None
    if quality.sky:
        sky = models.build_sky()
        sky.reparentTo(base.camera)
        sky.setEffect(CompassEffect.make(render))  # rotate with the world, not the camera
    return WorldScene(root, water, sky, sun_np, quality)


def graphics_prc(quality: Quality, offscreen: bool, title: str = "Skyrunner") -> str:
    """Panda3D config lines for this preset."""
    if offscreen:
        return "window-type offscreen\naudio-library-name null\nwin-size 1280 720"
    lines = ["win-size 1280 720", f"window-title {title}", "sync-video 1"]
    if quality.msaa:
        lines += ["framebuffer-multisample 1", f"multisamples {quality.msaa}"]
    return "\n".join(lines)
