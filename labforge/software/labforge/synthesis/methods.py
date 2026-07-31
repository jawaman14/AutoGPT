"""Batch vs continuous-flow synthesis: a small comparison model.

This captures the qualitative trade-offs LabForge cares about when a route can
be run either way, plus the one quantitative relationship that matters most for
flow: **residence time = reactor holdup / volumetric flow rate**.

It's intentionally lightweight — a decision aid and a source of truth for the
docs and the ``labforge methods`` command, not a process simulator.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import List


class Mode(str, Enum):
    BATCH = "batch"
    FLOW = "flow"


@dataclass
class MethodProfile:
    """Qualitative profile of a synthesis mode."""

    mode: Mode
    heat_transfer: str
    mass_transfer_mixing: str
    residence_control: str
    scale_up: str
    hazard_containment: str
    reagent_use: str
    good_for: List[str] = field(default_factory=list)
    watch_out_for: List[str] = field(default_factory=list)


BATCH = MethodProfile(
    mode=Mode.BATCH,
    heat_transfer="Limited by vessel surface-to-volume; hot/cold spots at scale.",
    mass_transfer_mixing="Depends on stirring; can be uneven in viscous or biphasic mixtures.",
    residence_control="Set by how long you leave it; easy to sample and extend.",
    scale_up="Bigger vessel = different mixing/heat transfer (non-trivial).",
    hazard_containment="Whole charge is reactive at once; large in-process inventory.",
    reagent_use="Flexible; easy to add solids, slurries, and do multi-step in one pot.",
    good_for=[
        "Slow reactions and long holds",
        "Solids, slurries, precipitations, crystallisations",
        "Exploratory chemistry and one-pot sequences",
        "Enzyme reactions run as a stirred incubation",
    ],
    watch_out_for=[
        "Exotherms (all reagents present together)",
        "Reproducibility of mixing/heat transfer when scaling",
    ],
)

FLOW = MethodProfile(
    mode=Mode.FLOW,
    heat_transfer="Excellent: narrow channels, high surface-to-volume, fast thermal response.",
    mass_transfer_mixing="Fast, reproducible mixing in tees/mixers; short diffusion paths.",
    residence_control="Precise: set by reactor volume and flow rate (see residence_time_min).",
    scale_up="Scale by running longer or numbering-up channels (same conditions).",
    hazard_containment="Small reactive inventory at any instant; safer for hazardous steps.",
    reagent_use="Steady feeds; awkward for solids/precipitates (clogging risk).",
    good_for=[
        "Fast or exothermic reactions",
        "Hazardous intermediates (small in-process inventory)",
        "Reproducible, tightly-controlled residence/temperature",
        "Packed-bed immobilised catalysts/enzymes, continuous hydrogenation",
    ],
    watch_out_for=[
        "Solids and precipitation (clogging)",
        "Very long residence times need long coils or slow flow",
        "Start-up/steady-state transients; collect only at steady state",
    ],
)

_PROFILES = {Mode.BATCH: BATCH, Mode.FLOW: FLOW}


def residence_time_min(reactor_holdup_ml: float, total_flow_ml_min: float) -> float:
    """Residence time (minutes) for a flow reactor.

    residence_time = reactor internal (holdup) volume / total volumetric flow.
    """
    if total_flow_ml_min <= 0:
        raise ValueError("total flow rate must be positive")
    return reactor_holdup_ml / total_flow_ml_min


def flow_rate_for_residence(reactor_holdup_ml: float, residence_min: float) -> float:
    """Inverse: total flow (mL/min) needed for a target residence time."""
    if residence_min <= 0:
        raise ValueError("residence time must be positive")
    return reactor_holdup_ml / residence_min


def compare_table() -> str:
    """Return a human-readable batch-vs-flow comparison."""
    rows = [
        ("Heat transfer", BATCH.heat_transfer, FLOW.heat_transfer),
        ("Mixing / mass transfer", BATCH.mass_transfer_mixing, FLOW.mass_transfer_mixing),
        ("Residence control", BATCH.residence_control, FLOW.residence_control),
        ("Scale-up", BATCH.scale_up, FLOW.scale_up),
        ("Hazard containment", BATCH.hazard_containment, FLOW.hazard_containment),
        ("Reagent handling", BATCH.reagent_use, FLOW.reagent_use),
    ]
    lines = ["Batch vs Flow", "=============", ""]
    for label, b, f in rows:
        lines.append(f"* {label}")
        lines.append(f"    batch: {b}")
        lines.append(f"    flow : {f}")
    lines.append("")
    lines.append("Batch is good for: " + "; ".join(BATCH.good_for))
    lines.append("Flow is good for : " + "; ".join(FLOW.good_for))
    return "\n".join(lines)


def profile(mode: Mode) -> MethodProfile:
    return _PROFILES[Mode(mode)]
