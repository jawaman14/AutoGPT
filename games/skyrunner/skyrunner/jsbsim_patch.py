"""Prepare JSBSim aircraft definitions for the game.

Stock JSBSim models declare between 0 and 5 point masses, but the game needs one
per load station. Point-mass *locations* are writable at runtime; the *count*
is fixed at load time. So we build a mirror of the JSBSim data root where the
aircraft XML has its <pointmass> list replaced by the game's stations, and
everything else (engines, systems, props, other files) is symlinked through.
"""
from __future__ import annotations

import os
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

import jsbsim

from .aircraft import AircraftSpec

_UNIT_TO_IN = {"IN": 1.0, "FT": 12.0, "M": 39.3701}
_UNIT_TO_LB = {"LBS": 1.0, "KG": 2.20462}


@dataclass(frozen=True)
class MassData:
    empty_lb: float
    empty_cg_x_in: float
    tanks: tuple[tuple[float, float], ...]  # (x_in, capacity_lb)
    gear_height_ft: float  # CG height above ground when sitting on the gear

    @property
    def fuel_capacity_lb(self) -> float:
        return sum(c for _, c in self.tanks)


def _loc_in(el: ET.Element, axis: str) -> float:
    loc = el if el.tag == "location" else el.find("location")
    return float(loc.find(axis).text) * _UNIT_TO_IN[loc.get("unit", "IN").upper()]


def read_mass_data(model: str, root: str | None = None) -> MassData:
    root = root or jsbsim.get_default_root_dir()
    tree = ET.parse(os.path.join(root, "aircraft", model, f"{model}.xml")).getroot()
    mb = tree.find("mass_balance")
    empty = mb.find("emptywt")
    empty_lb = float(empty.text) * _UNIT_TO_LB[empty.get("unit", "LBS").upper()]
    cg = mb.find("location[@name='CG']")
    tanks = []
    for t in tree.iter("tank"):
        if t.get("type", "FUEL").upper() != "FUEL":
            continue
        cap = t.find("capacity")
        tanks.append((_loc_in(t, "x"), float(cap.text) * _UNIT_TO_LB[cap.get("unit", "LBS").upper()]))
    gear_z = [
        _loc_in(c, "z")
        for c in tree.find("ground_reactions").iter("contact")
        if c.get("type") == "BOGEY"
    ]
    return MassData(
        empty_lb=empty_lb,
        empty_cg_x_in=_loc_in(cg, "x"),
        tanks=tuple(tanks),
        gear_height_ft=(_loc_in(cg, "z") - min(gear_z)) / 12.0,
    )


def _pointmass(name: str, x: float, y: float, z: float) -> ET.Element:
    pm = ET.Element("pointmass", name=name)
    ET.SubElement(pm, "weight", unit="LBS").text = "0"
    loc = ET.SubElement(pm, "location", unit="IN")
    for axis, v in zip("xyz", (x, y, z)):
        ET.SubElement(loc, axis).text = f"{v:.2f}"
    return pm


def build_patched_root(specs: list[AircraftSpec], cache_dir: str | None = None) -> str:
    """Return a JSBSim root dir whose aircraft carry the game's load stations."""
    src = Path(jsbsim.get_default_root_dir())
    dst = Path(cache_dir or os.path.join(tempfile.gettempdir(), "skyrunner-jsbsim"))
    (dst / "aircraft").mkdir(parents=True, exist_ok=True)
    for entry in src.iterdir():
        if entry.name == "aircraft" or not entry.is_dir():
            continue
        link = dst / entry.name
        if not link.exists():
            link.symlink_to(entry, target_is_directory=True)

    for spec in specs:
        model = spec.jsbsim_model
        adir = dst / "aircraft" / model
        adir.mkdir(exist_ok=True)
        for entry in (src / "aircraft" / model).iterdir():
            link = adir / entry.name
            if entry.name != f"{model}.xml" and not link.exists():
                link.symlink_to(entry, target_is_directory=entry.is_dir())
        tree = ET.parse(src / "aircraft" / model / f"{model}.xml")
        mb = tree.getroot().find("mass_balance")
        for pm in mb.findall("pointmass"):
            mb.remove(pm)
        for st in spec.stations:
            mb.append(_pointmass(st.name, st.x_in, st.y_in, st.z_in))
        tree.write(adir / f"{model}.xml", xml_declaration=True, encoding="utf-8")
    return str(dst)
