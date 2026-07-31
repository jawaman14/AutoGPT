"""Parse XDL (Chemical Description Language) XML into LabForge objects.

LabForge targets the widely-used XDL structure::

    <Synthesis>
      <Hardware>
        <Component id="reactor" type="reactor"/>
      </Hardware>
      <Reagents>
        <Reagent id="water" name="water" molar_mass="18.02"/>
      </Reagents>
      <Procedure>
        <Add reagent="water" vessel="reactor" volume="10 mL"/>
        ...
      </Procedure>
    </Synthesis>

Some XDL exporters wrap everything in an ``<XDL>`` root and/or split the
procedure into ``<Prep>``, ``<Reaction>`` and ``<Workup>`` blocks; both are
handled. This parser is intentionally standalone (no dependency on the Cronin
Group toolchain) so LabForge stays MIT-licensed and portable.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from typing import Optional

from labforge.protocol.model import Component, Protocol, Reagent
from labforge.protocol.steps import build_step

# Procedure steps may be nested one level inside these grouping tags.
_PROCEDURE_GROUPS = {"Procedure", "Prep", "Reaction", "Workup", "Purification"}


class XDLParseError(ValueError):
    """Raised when an XDL document is malformed or missing required sections."""


def _find_synthesis(root: ET.Element) -> ET.Element:
    if root.tag == "Synthesis":
        return root
    # An <XDL> (or other) wrapper: find the first <Synthesis> child.
    found = root.find(".//Synthesis")
    if found is not None:
        return found
    # Some minimal files use <XDL> directly as the synthesis container.
    if root.find("Procedure") is not None or root.find("Hardware") is not None:
        return root
    raise XDLParseError("no <Synthesis> element found in XDL document")


def _parse_hardware(synthesis: ET.Element):
    components = []
    hardware = synthesis.find("Hardware")
    if hardware is None:
        return components
    for el in hardware:
        cid = el.attrib.get("id")
        if not cid:
            continue
        components.append(
            Component(
                id=cid,
                type=el.attrib.get("type", el.tag.lower()),
                attrs=dict(el.attrib),
            )
        )
    return components


def _parse_float(value: Optional[str]) -> Optional[float]:
    if value is None or str(value).strip() == "":
        return None
    try:
        return float(str(value).split()[0])
    except (TypeError, ValueError):
        return None


def _parse_reagents(synthesis: ET.Element):
    reagents = {}
    section = synthesis.find("Reagents")
    if section is None:
        return reagents
    for el in section:
        rid = el.attrib.get("id") or el.attrib.get("name")
        if not rid:
            continue
        reagents[rid] = Reagent(
            id=rid,
            name=el.attrib.get("name", rid),
            smiles=el.attrib.get("smiles") or el.attrib.get("inchi"),
            molar_mass=_parse_float(el.attrib.get("molar_mass")),
            concentration=el.attrib.get("concentration"),
            role=el.attrib.get("role"),
            attrs=dict(el.attrib),
        )
    return reagents


def _iter_procedure_steps(synthesis: ET.Element):
    for child in synthesis:
        if child.tag in _PROCEDURE_GROUPS:
            for step_el in child:
                yield step_el


def _parse_procedure(synthesis: ET.Element):
    steps = []
    for step_el in _iter_procedure_steps(synthesis):
        steps.append(build_step(step_el.tag, dict(step_el.attrib)))
    return steps


def parse_xdl(text: str, name: Optional[str] = None) -> Protocol:
    """Parse an XDL document from a string."""
    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        raise XDLParseError(f"invalid XML: {exc}") from exc

    synthesis = _find_synthesis(root)
    protocol = Protocol(
        name=name or synthesis.attrib.get("name") or root.attrib.get("name") or "procedure",
        hardware=_parse_hardware(synthesis),
        reagents=_parse_reagents(synthesis),
        steps=_parse_procedure(synthesis),
    )
    if not protocol.steps:
        raise XDLParseError("procedure contains no steps")
    return protocol


def parse_xdl_file(path) -> Protocol:
    """Parse an XDL document from a file path."""
    import os

    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    return parse_xdl(text, name=os.path.splitext(os.path.basename(str(path)))[0])
