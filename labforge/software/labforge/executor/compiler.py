"""The LabForge "chempiler": XDL steps -> low-level device operations.

The compiler is where all resolution and *static safety checking* happens:

* Every step is resolved against the :class:`HardwareGraph` (which pump moves
  this reagent to that vessel? which stirrer serves this vessel?). A step that
  can't be wired is a hard :class:`CompileError` — never a silent skip.
* A dry volume model tracks each vessel's contents so overflow / drawing from
  an empty vessel is caught *before* a drop of liquid moves.
* Unsupported XDL tags abort compilation, so a procedure containing chemistry
  LabForge can't perform will refuse to run rather than do it partially.

The output is a flat list of :class:`Operation` objects the runtime executes.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional

from labforge.graph.hardware_graph import HardwareGraph
from labforge.protocol.model import Protocol
from labforge.protocol import steps as S


class CompileError(ValueError):
    """Raised when a procedure cannot be mapped safely onto the hardware graph."""


@dataclass
class Operation:
    """A single low-level action for the runtime to perform."""

    kind: str  # pump|stir|stop_stir|heat|heat_off|wait|read_temp|home|comment
    description: str
    device_id: Optional[str] = None
    volume_ml: Optional[float] = None
    rate_ml_s: Optional[float] = None
    rpm: Optional[float] = None
    temp_c: Optional[float] = None
    time_s: Optional[float] = None
    text: Optional[str] = None
    # Bookkeeping only: vessel volume deltas this op applies (for reporting).
    volume_deltas: Dict[str, float] = field(default_factory=dict)


@dataclass
class CompiledRun:
    """Result of compiling a protocol against a graph."""

    protocol_name: str
    operations: List[Operation]
    final_volumes: Dict[str, float]
    warnings: List[str] = field(default_factory=list)
    #: Informational (non-warning) notes, e.g. computed flow residence times.
    notes: List[str] = field(default_factory=list)

    def total_time_s(self) -> float:
        return sum(op.time_s or 0.0 for op in self.operations)

    def describe(self) -> str:
        lines = [f"Compiled '{self.protocol_name}': {len(self.operations)} operation(s)"]
        for i, op in enumerate(self.operations, 1):
            lines.append(f"  {i:>3}. {op.description}")
        return "\n".join(lines)


class _VolumeModel:
    """Tracks vessel volumes during compilation for overflow/underflow checks."""

    def __init__(self, graph: HardwareGraph):
        self.graph = graph
        self.volumes: Dict[str, float] = {
            v.id: v.initial_volume_ml for v in graph.vessels.values()
        }

    def get(self, vessel_id: str) -> float:
        return self.volumes.get(vessel_id, 0.0)

    def add(self, vessel_id: str, delta: float):
        # Only track declared vessels; reagent stock sources are treated as
        # effectively unlimited unless declared as a vessel.
        if vessel_id not in self.graph.vessels:
            return
        vessel = self.graph.vessels[vessel_id]
        # Flow reactors / tees do not accumulate: forward to their outlet.
        if vessel.passthrough:
            if vessel.outlet:
                self.add(vessel.outlet, delta)
            return
        new_vol = self.volumes[vessel_id] + delta
        eps = 1e-6
        if new_vol < -eps:
            raise CompileError(
                f"vessel '{vessel_id}' would go negative "
                f"({self.volumes[vessel_id]:g} + {delta:g} mL): not enough liquid to move"
            )
        if new_vol > vessel.max_volume_ml + eps:
            raise CompileError(
                f"vessel '{vessel_id}' would overflow: {new_vol:g} mL "
                f"> capacity {vessel.max_volume_ml:g} mL"
            )
        self.volumes[vessel_id] = max(0.0, new_vol)


class _Compiler:
    def __init__(self, protocol: Protocol, graph: HardwareGraph):
        self.protocol = protocol
        self.graph = graph
        self.vol = _VolumeModel(graph)
        self.ops: List[Operation] = []
        self.warnings: List[str] = []
        self.notes: List[str] = []

    # -- helpers -----------------------------------------------------------
    def _require_pump(self, source: str, dest: str, context: str):
        pump = self.graph.find_pump(source, dest)
        if pump is None:
            raise CompileError(
                f"{context}: no pump wired from '{source}' to '{dest}'. "
                f"Add a pump with that source/dest to the hardware graph."
            )
        return pump

    def _require_stirrer(self, vessel: str, context: str):
        stirrer = self.graph.stirrer_for(vessel)
        if stirrer is None:
            raise CompileError(f"{context}: no stirrer attached to vessel '{vessel}'.")
        return stirrer

    def _require_heater(self, vessel: str, context: str):
        heater = self.graph.heater_for(vessel)
        if heater is None:
            raise CompileError(f"{context}: no heater attached to vessel '{vessel}'.")
        return heater

    def _accumulating(self, node: str):
        """Resolve a node to the vessel that actually accumulates its liquid,
        following flow-reactor pass-through outlets. Returns an id or None."""
        vessel = self.graph.vessels.get(node)
        seen = set()
        while vessel is not None and vessel.passthrough and vessel.outlet:
            if vessel.id in seen:  # guard against a wiring loop
                return None
            seen.add(vessel.id)
            vessel = self.graph.vessels.get(vessel.outlet)
        if vessel is not None and not vessel.passthrough:
            return vessel.id
        return None

    def _pump_transfer(self, source, dest, volume_ml, rate_ml_s, context):
        pump = self._require_pump(source, dest, context)
        if volume_ml <= 0:
            raise CompileError(f"{context}: volume must be positive, got {volume_ml}")
        if volume_ml > pump.syringe_volume_ml + 1e-6 and pump.kind == "syringe":
            # A single syringe stroke can't exceed the barrel; warn (firmware
            # can chunk, but flag it so the user knows multiple strokes happen).
            self.warnings.append(
                f"{context}: {volume_ml:g} mL exceeds syringe barrel "
                f"({pump.syringe_volume_ml:g} mL); pump '{pump.id}' will use multiple strokes."
            )
        # Update the dry volume model (pass-through reactors forward to outlet).
        self.vol.add(source, -volume_ml)
        self.vol.add(dest, +volume_ml)
        # Report deltas against the vessels that actually accumulate.
        deltas = {}
        src_acc = self._accumulating(source)
        dst_acc = self._accumulating(dest)
        if src_acc:
            deltas[src_acc] = deltas.get(src_acc, 0.0) - volume_ml
        if dst_acc:
            deltas[dst_acc] = deltas.get(dst_acc, 0.0) + volume_ml

        delivery_s = (volume_ml / rate_ml_s) if rate_ml_s else None

        # Flow: if the destination is a flow reactor, report the residence time.
        reactor = self.graph.flow_reactor_on_route(source, dest)
        rate_tag = ""
        if reactor is not None and rate_ml_s:
            holdup = reactor.max_volume_ml
            residence_min = holdup / (rate_ml_s * 60.0)
            self.notes.append(
                f"{context}: flow through '{reactor.id}' at "
                f"{rate_ml_s * 60.0:g} mL/min, holdup {holdup:g} mL "
                f"=> residence ~{residence_min:.1f} min"
            )
            rate_tag = f" @ {rate_ml_s * 60.0:g} mL/min"

        self.ops.append(
            Operation(
                kind="pump",
                description=f"pump {volume_ml:g} mL: {source} -> {dest} (via {pump.id}){rate_tag}",
                device_id=pump.id,
                volume_ml=volume_ml,
                rate_ml_s=rate_ml_s,
                time_s=delivery_s,
                volume_deltas=deltas,
            )
        )

    @staticmethod
    def _rate_ml_s(step, volume_ml):
        """Derive a mL/s pump rate from a step's flow_rate (mL/min) or time."""
        flow = getattr(step, "flow_rate_ml_min", None)
        if flow:
            return flow / 60.0
        if getattr(step, "time_s", None):
            return volume_ml / step.time_s
        return None

    # -- per-step compilation ---------------------------------------------
    def _add(self, step: S.Add):
        ctx = f"Add {step.reagent}->{step.vessel}"
        if step.volume_ml is None:
            raise CompileError(f"{ctx}: 'volume' is required")
        source = self.graph.source_for_reagent(step.reagent)
        if step.stir:
            stirrer = self.graph.stirrer_for(step.vessel)
            if stirrer is not None:
                self.ops.append(
                    Operation(
                        kind="stir",
                        description=f"start stirring {step.vessel} (during Add)",
                        device_id=stirrer.id,
                        rpm=stirrer.default_rpm,
                    )
                )
        rate = self._rate_ml_s(step, step.volume_ml)
        self._pump_transfer(source, step.vessel, step.volume_ml, rate, ctx)

    def _transfer(self, step: S.Transfer):
        ctx = f"Transfer {step.from_vessel}->{step.to_vessel}"
        volume = step.volume_ml
        if volume is None:  # "all"
            volume = self.vol.get(step.from_vessel)
            if volume <= 0:
                raise CompileError(
                    f"{ctx}: asked to transfer all, but '{step.from_vessel}' is empty"
                )
        rate = self._rate_ml_s(step, volume)
        self._pump_transfer(step.from_vessel, step.to_vessel, volume, rate, ctx)

    def _stir(self, step: S.Stir):
        ctx = f"Stir {step.vessel}"
        stirrer = self._require_stirrer(step.vessel, ctx)
        rpm = step.speed_rpm if step.speed_rpm is not None else stirrer.default_rpm
        self.ops.append(
            Operation(
                kind="stir",
                description=f"stir {step.vessel} at {rpm:g} RPM",
                device_id=stirrer.id,
                rpm=rpm,
            )
        )
        if step.time_s is not None:
            self.ops.append(
                Operation(
                    kind="wait",
                    description=f"hold stir for {step.time_s:g} s",
                    time_s=step.time_s,
                )
            )
            self.ops.append(
                Operation(
                    kind="stop_stir",
                    description=f"stop stirring {step.vessel}",
                    device_id=stirrer.id,
                )
            )

    def _stop_stir(self, step: S.StopStir):
        stirrer = self._require_stirrer(step.vessel, f"StopStir {step.vessel}")
        self.ops.append(
            Operation(
                kind="stop_stir",
                description=f"stop stirring {step.vessel}",
                device_id=stirrer.id,
            )
        )

    def _heatchill(self, step: S.HeatChill):
        ctx = f"HeatChill {step.vessel}"
        heater = self._require_heater(step.vessel, ctx)
        if step.temp_c is None:
            raise CompileError(f"{ctx}: 'temp' is required")
        if step.temp_c > heater.max_temp_c:
            raise CompileError(
                f"{ctx}: setpoint {step.temp_c:g} °C exceeds heater max "
                f"{heater.max_temp_c:g} °C"
            )
        if step.stir:
            stirrer = self.graph.stirrer_for(step.vessel)
            if stirrer is not None:
                self.ops.append(
                    Operation(
                        kind="stir",
                        description=f"start stirring {step.vessel} (during HeatChill)",
                        device_id=stirrer.id,
                        rpm=stirrer.default_rpm,
                    )
                )
        self.ops.append(
            Operation(
                kind="heat",
                description=f"heat {step.vessel} to {step.temp_c:g} °C",
                device_id=heater.id,
                temp_c=step.temp_c,
            )
        )
        if step.time_s is not None:
            self.ops.append(
                Operation(
                    kind="wait",
                    description=f"hold {step.temp_c:g} °C for {step.time_s:g} s",
                    time_s=step.time_s,
                )
            )

    def _wait(self, step: S.Wait):
        self.ops.append(
            Operation(kind="wait", description=f"wait {step.time_s:g} s", time_s=step.time_s)
        )

    def _clean(self, step: S.CleanVessel):
        ctx = f"CleanVessel {step.vessel}"
        if step.volume_ml is None:
            raise CompileError(f"{ctx}: 'volume' is required")
        solvent_source = self.graph.source_for_reagent(step.solvent)
        # Cleaning needs a route in (solvent -> vessel) and out (vessel -> waste).
        self._require_pump(solvent_source, step.vessel, ctx + " (fill)")
        self._require_pump(step.vessel, "waste", ctx + " (drain)")
        for i in range(step.repeats):
            self._pump_transfer(
                solvent_source, step.vessel, step.volume_ml, None, f"{ctx} rinse {i + 1}"
            )
            self._pump_transfer(
                step.vessel, "waste", step.volume_ml, None, f"{ctx} drain {i + 1}"
            )

    def _comment(self, step: S.Comment):
        self.ops.append(
            Operation(kind="comment", description=f"# {step.text}", text=step.text)
        )

    def compile(self) -> CompiledRun:
        unsupported = self.protocol.unsupported_steps()
        if unsupported:
            names = ", ".join(sorted({s.xdl_name for s in unsupported}))
            raise CompileError(
                f"procedure uses XDL step(s) LabForge cannot execute: {names}. "
                f"Supported steps: {', '.join(sorted(S.supported_tags()))}."
            )

        dispatch = {
            S.Add: self._add,
            S.Transfer: self._transfer,
            S.Stir: self._stir,
            S.StopStir: self._stop_stir,
            S.HeatChill: self._heatchill,
            S.Wait: self._wait,
            S.CleanVessel: self._clean,
            S.Comment: self._comment,
        }
        for step in self.protocol.steps:
            handler = dispatch.get(type(step))
            if handler is None:  # pragma: no cover - guarded by unsupported check
                raise CompileError(f"no compiler for step {step.xdl_name}")
            handler(step)

        return CompiledRun(
            protocol_name=self.protocol.name,
            operations=self.ops,
            final_volumes=dict(self.vol.volumes),
            warnings=self.warnings,
            notes=self.notes,
        )


def compile_protocol(protocol: Protocol, graph: HardwareGraph) -> CompiledRun:
    """Compile a parsed :class:`Protocol` against a :class:`HardwareGraph`."""
    return _Compiler(protocol, graph).compile()
