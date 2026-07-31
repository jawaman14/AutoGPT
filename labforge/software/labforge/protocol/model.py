"""Container objects for a parsed XDL procedure."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional

from labforge.protocol.steps import Step, UnsupportedStep


@dataclass
class Component:
    """A piece of hardware declared in the ``<Hardware>`` section of an XDL file."""

    id: str
    type: str = "reactor"
    attrs: dict = field(default_factory=dict)


@dataclass
class Reagent:
    """A reagent declared in the ``<Reagents>`` section of an XDL file."""

    id: str
    name: str = ""
    smiles: Optional[str] = None
    molar_mass: Optional[float] = None  # g/mol, if given explicitly
    concentration: Optional[str] = None  # kept as raw XDL string, e.g. "1 mol/L"
    role: Optional[str] = None
    attrs: dict = field(default_factory=dict)


@dataclass
class Protocol:
    """A fully parsed XDL procedure."""

    name: str = "procedure"
    hardware: List[Component] = field(default_factory=list)
    reagents: Dict[str, Reagent] = field(default_factory=dict)
    steps: List[Step] = field(default_factory=list)

    def unsupported_steps(self) -> List[UnsupportedStep]:
        return [s for s in self.steps if isinstance(s, UnsupportedStep)]

    def component(self, component_id: str) -> Optional[Component]:
        for c in self.hardware:
            if c.id == component_id:
                return c
        return None

    def describe(self) -> str:
        lines = [f"Procedure: {self.name}", f"  {len(self.steps)} step(s)"]
        for i, step in enumerate(self.steps, 1):
            lines.append(f"  {i:>3}. {step.summary()}")
        return "\n".join(lines)
