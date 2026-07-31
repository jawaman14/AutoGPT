"""Protocol decoders.

Rather than re-implementing DSP, RFHound keeps a registry of *decoder recipes*.
Each recipe knows which external tool it needs, how to build the command for a
given frequency, and what it produces. This keeps RFHound honest (it never
pretends to decode something it can't) and extensible (add a recipe = add a
capability).

All recipes are receive-only.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from .. import proc
from ..config import Config
from ..exceptions import DependencyMissingError


@dataclass
class Recipe:
    id: str
    name: str
    category: str
    tool: str
    default_freq_hz: int
    description: str
    # Build the argv for this recipe given (cfg, freq_hz, seconds).
    build: Callable[[Config, int, float], list[str]]
    # Legal / usage note surfaced to the operator.
    note: str = ""


def _rtl433(cfg: Config, freq_hz: int, seconds: float) -> list[str]:
    # rtl_433 with a SoapySDR HackRF source; -F json for machine-readable output.
    return [
        "rtl_433",
        "-d", "driver=hackrf",
        "-f", str(freq_hz),
        "-F", "json",
        "-M", "level",
    ]


def _adsb(cfg: Config, freq_hz: int, seconds: float) -> list[str]:
    # dump1090 built with SoapySDR/HackRF support.
    return [
        "dump1090",
        "--device-type", "hackrf",
        "--freq", str(freq_hz),
        "--net",
    ]


def _pocsag(cfg: Config, freq_hz: int, seconds: float) -> list[str]:
    # multimon-ng expects demodulated audio on stdin; RFHound documents the
    # canonical pipeline. Here we surface the multimon-ng half; the front-end
    # FM demod is provided in docs/USAGE.md (hackrf_transfer | csdr | ...).
    return [
        "multimon-ng",
        "-a", "POCSAG512",
        "-a", "POCSAG1200",
        "-a", "POCSAG2400",
        "-f", "alpha",
        "-",
    ]


def _aprs(cfg: Config, freq_hz: int, seconds: float) -> list[str]:
    return ["multimon-ng", "-a", "AFSK1200", "-A", "-"]


def _ais(cfg: Config, freq_hz: int, seconds: float) -> list[str]:
    return ["AIS-catcher", "-d", "driver=hackrf", "-v"]


def _acars(cfg: Config, freq_hz: int, seconds: float) -> list[str]:
    return ["acarsdec", "-r", "hackrf", str(freq_hz)]


RECIPES: dict[str, Recipe] = {
    "rtl433": Recipe(
        "rtl433", "ISM device decoder (rtl_433)", "ism", "rtl_433",
        433_920_000,
        "Decodes hundreds of 300-928 MHz devices: TPMS, weather stations, "
        "temperature/door/PIR sensors, some remotes. The best first decoder.",
        _rtl433,
        note="Passive receive. Great for asset discovery in a facility.",
    ),
    "adsb": Recipe(
        "adsb", "ADS-B aircraft (dump1090)", "aviation", "dump1090",
        1_090_000_000,
        "Decodes aircraft ICAO id, position, altitude, velocity at 1090 MHz.",
        _adsb,
        note="Passive, legal to receive in most jurisdictions.",
    ),
    "pocsag": Recipe(
        "pocsag", "POCSAG/FLEX pagers (multimon-ng)", "paging", "multimon-ng",
        929_000_000,
        "Decodes pager messages, which are frequently unencrypted. Demonstrates "
        "cleartext-messaging risk in an environment.",
        _pocsag,
        note="Requires an FM-demod front-end feeding stdin (see docs/USAGE.md). "
             "Pager content may be personal data — handle per your rules of "
             "engagement.",
    ),
    "aprs": Recipe(
        "aprs", "APRS packet radio (multimon-ng)", "amateur", "multimon-ng",
        144_390_000,
        "Decodes AFSK1200 APRS position/telemetry packets.",
        _aprs,
        note="Requires FM-demod front-end feeding stdin.",
    ),
    "ais": Recipe(
        "ais", "AIS vessel tracking (AIS-catcher)", "maritime", "AIS-catcher",
        162_000_000,
        "Decodes ship position/identity beacons (MMSI, position, course).",
        _ais,
        note="Passive receive.",
    ),
    "acars": Recipe(
        "acars", "ACARS aircraft messaging (acarsdec)", "aviation", "acarsdec",
        131_550_000,
        "Decodes aircraft/ground text messaging around 131 MHz.",
        _acars,
        note="Passive receive.",
    ),
}


def list_recipes() -> list[Recipe]:
    return list(RECIPES.values())


def get_recipe(recipe_id: str) -> Recipe | None:
    return RECIPES.get(recipe_id)


def check_recipe(recipe: Recipe) -> tuple[bool, str | None]:
    """Return (available, path) for a recipe's required tool."""
    path = proc.find_tool(recipe.tool)
    return path is not None, path


def build_command(
    recipe: Recipe, cfg: Config, *, freq_hz: int | None = None, seconds: float = 30
) -> list[str]:
    return recipe.build(cfg, freq_hz or recipe.default_freq_hz, seconds)


def run_decoder(
    recipe: Recipe,
    cfg: Config,
    *,
    freq_hz: int | None = None,
    seconds: float = 30,
    on_line: Callable[[str], None] | None = None,
    dry_run: bool = False,
) -> list[str]:
    """Run a decoder recipe, collecting output lines. Returns the lines.

    With dry_run=True, returns a single element: the command that *would* run.
    """
    cmd = build_command(recipe, cfg, freq_hz=freq_hz, seconds=seconds)
    if dry_run:
        return [proc.format_command(cmd)]
    if not proc.find_tool(recipe.tool):
        from ..proc import KNOWN_TOOLS
        hint = KNOWN_TOOLS[recipe.tool].install_hint if recipe.tool in KNOWN_TOOLS else None
        raise DependencyMissingError(recipe.tool, hint)
    lines: list[str] = []

    def _collect(line: str) -> None:
        lines.append(line)
        if on_line:
            on_line(line)

    proc.stream(cmd, on_line=_collect, timeout=seconds)
    return lines
