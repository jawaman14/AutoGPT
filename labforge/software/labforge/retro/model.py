"""Data model for curated retrosynthesis + route export."""

from __future__ import annotations

import itertools
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from labforge.synthesis.methods import Mode


@dataclass(frozen=True)
class Molecule:
    """A chemical species referenced in a route."""

    name: str
    smiles: Optional[str] = None
    cas: Optional[str] = None
    note: Optional[str] = None

    def label(self) -> str:
        extra = f" [{self.smiles}]" if self.smiles else ""
        return f"{self.name}{extra}"


@dataclass
class ModeXDL:
    """The XDL fragments needed to run one reaction step in one mode.

    ``hardware`` / ``reagents`` are lists of raw XDL element strings (e.g.
    ``'<Component id="reactor" type="reactor"/>'``); ``procedure`` is the list
    of procedure-step element strings. They are merged and de-duplicated when a
    whole route is assembled.
    """

    hardware: List[str] = field(default_factory=list)
    reagents: List[str] = field(default_factory=list)
    procedure: List[str] = field(default_factory=list)


@dataclass
class ReactionStep:
    """A forward reaction: reactants + conditions -> product."""

    name: str
    description: str
    reactants: List[Molecule]
    product: Molecule
    reaction_class: str = "reaction"
    modes: List[Mode] = field(default_factory=lambda: [Mode.BATCH])
    conditions: str = ""
    reagents_aux: List[str] = field(default_factory=list)
    #: LabForge can compile/run this step (has XDL fragments) vs. planning-only.
    executable: bool = False
    xdl: Dict[Mode, ModeXDL] = field(default_factory=dict)

    def supports(self, mode: Mode) -> bool:
        return Mode(mode) in self.modes

    def mode_summary(self) -> str:
        return "/".join(m.value for m in self.modes)


@dataclass
class Disconnection:
    """A retrosynthetic step: target <= precursors, via a named transform."""

    name: str
    description: str
    forward: ReactionStep
    precursors: List["RetroNode"]
    reaction_class: str = "reaction"

    @property
    def modes(self) -> List[Mode]:
        return self.forward.modes


@dataclass
class RetroNode:
    """A node in the retrosynthetic tree (a molecule and how to make it)."""

    molecule: Molecule
    disconnections: List[Disconnection] = field(default_factory=list)

    @property
    def is_leaf(self) -> bool:
        return not self.disconnections

    def render(self, indent: int = 0) -> str:
        pad = "  " * indent
        if self.is_leaf:
            return f"{pad}- {self.molecule.label()}  (starting material)"
        lines = [f"{pad}* {self.molecule.label()}"]
        for disc in self.disconnections:
            modes = "/".join(m.value for m in disc.modes)
            lines.append(f"{pad}  => [{disc.name}; {disc.reaction_class}; {modes}]")
            lines.append(f"{pad}     {disc.description}")
            for pre in disc.precursors:
                lines.append(pre.render(indent + 3))
        return "\n".join(lines)


@dataclass
class Route:
    """A concrete forward sequence of reaction steps to a target."""

    target: Molecule
    steps: List[ReactionStep]
    name: str = "route"

    @property
    def executable(self) -> bool:
        return all(s.executable for s in self.steps)

    def modes(self) -> List[Mode]:
        """Modes supported by *every* step (i.e. the whole route)."""
        common = set(Mode)
        for s in self.steps:
            common &= set(s.modes)
        return [m for m in Mode if m in common]

    def render(self) -> str:
        lines = [f"Route to {self.target.label()} ({len(self.steps)} step(s)):"]
        for i, s in enumerate(self.steps, 1):
            tag = "" if s.executable else "  [planning-only on this rig class]"
            lines.append(f"  {i}. {s.name} [{s.reaction_class}; {s.mode_summary()}]{tag}")
            lines.append(f"       {' + '.join(r.name for r in s.reactants)} -> {s.product.name}")
            if s.conditions:
                lines.append(f"       conditions: {s.conditions}")
        return "\n".join(lines)

    def to_xdl(self, mode: Mode, name: Optional[str] = None) -> str:
        """Assemble a runnable XDL document for the given mode.

        Raises ``ValueError`` if any step lacks executable XDL for ``mode``.
        """
        mode = Mode(mode)
        hardware: List[str] = []
        reagents: List[str] = []
        procedure: List[str] = []

        def add_unique(dst, items):
            for it in items:
                if it not in dst:
                    dst.append(it)

        for step in self.steps:
            if not step.executable or mode not in step.xdl:
                raise ValueError(
                    f"step '{step.name}' has no executable XDL for mode '{mode.value}'"
                )
            frag = step.xdl[mode]
            add_unique(hardware, frag.hardware)
            add_unique(reagents, frag.reagents)
            procedure.extend(frag.procedure)

        doc_name = name or f"{self.target.name.replace(' ', '_')}_{mode.value}"
        ind = "    "
        parts = ['<?xml version="1.0" encoding="UTF-8"?>']
        parts.append(f'<Synthesis name="{doc_name}">')
        parts.append("  <Hardware>")
        parts += [ind + h for h in hardware]
        parts.append("  </Hardware>")
        parts.append("  <Reagents>")
        parts += [ind + r for r in reagents]
        parts.append("  </Reagents>")
        parts.append("  <Procedure>")
        parts += [ind + p for p in procedure]
        parts.append("  </Procedure>")
        parts.append("</Synthesis>")
        return "\n".join(parts) + "\n"


def enumerate_routes(node: RetroNode) -> List[Route]:
    """Enumerate all complete forward routes implied by a retro tree."""

    def _step_lists(n: RetroNode) -> List[List[ReactionStep]]:
        if n.is_leaf:
            return [[]]
        out: List[List[ReactionStep]] = []
        for disc in n.disconnections:
            per_precursor = [_step_lists(p) for p in disc.precursors]
            for combo in itertools.product(*per_precursor):
                steps: List[ReactionStep] = []
                for sub in combo:  # make precursors first (forward order)
                    steps.extend(sub)
                steps.append(disc.forward)
                out.append(steps)
        return out

    routes = []
    for i, steps in enumerate(_step_lists(node), 1):
        routes.append(Route(target=node.molecule, steps=steps, name=f"route-{i}"))
    return routes
