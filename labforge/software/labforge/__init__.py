"""LabForge: XDL-native, ESP32-driven, 3D-printable lab automation.

Public API surface is intentionally small; import the submodules directly for
anything advanced.
"""

from labforge.protocol.steps import (  # noqa: F401
    Add,
    CleanVessel,
    Comment,
    HeatChill,
    Step,
    Stir,
    StopStir,
    Transfer,
    Wait,
)
from labforge.protocol.model import Protocol, Component, Reagent  # noqa: F401
from labforge.protocol.xdl_parser import parse_xdl, parse_xdl_file  # noqa: F401
from labforge.graph.hardware_graph import HardwareGraph  # noqa: F401

__version__ = "0.1.0"

__all__ = [
    "Add",
    "Transfer",
    "Stir",
    "StopStir",
    "HeatChill",
    "Wait",
    "CleanVessel",
    "Comment",
    "Step",
    "Protocol",
    "Component",
    "Reagent",
    "parse_xdl",
    "parse_xdl_file",
    "HardwareGraph",
    "__version__",
]
