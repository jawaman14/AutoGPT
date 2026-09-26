"""Panda3D config generation. No GPU/X server needed: these just check the
config string, not that a window actually opens."""
from skyrunner.render.quality import get as quality_preset
from skyrunner.render.scene import graphics_prc


def test_offscreen_config_falls_back_to_software_rendering():
    # A bot-testing box has no GPU and no X server. Without an explicit
    # fallback, Panda3D raises "Could not open window" instead of rendering
    # with the software rasteriser (regression: --watch and the balance sims
    # crashed on any headless machine).
    prc = graphics_prc(quality_preset("low"), offscreen=True)
    assert "window-type offscreen" in prc
    assert "p3tinydisplay" in prc


def test_onscreen_config_has_no_offscreen_lines():
    prc = graphics_prc(quality_preset("high"), offscreen=False)
    assert "window-type offscreen" not in prc
    assert "win-size 1280 720" in prc
