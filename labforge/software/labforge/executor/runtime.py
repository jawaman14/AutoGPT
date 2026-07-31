"""Execute a :class:`CompiledRun` against real or simulated devices."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional

from labforge.devices.registry import DeviceBundle
from labforge.executor.compiler import CompiledRun, Operation
from labforge.transport.protocol import Command


@dataclass
class RunResult:
    """Summary of an executed run."""

    protocol_name: str
    operations_run: int = 0
    elapsed_s: float = 0.0
    final_volumes: Dict[str, float] = field(default_factory=dict)
    log: List[str] = field(default_factory=list)
    aborted: bool = False
    error: Optional[str] = None


class _State:
    def __init__(self, initial: Dict[str, float]):
        self.volumes = dict(initial)

    def apply(self, deltas: Dict[str, float]):
        for vessel, delta in deltas.items():
            self.volumes[vessel] = self.volumes.get(vessel, 0.0) + delta


def _emergency_stop(bundle: DeviceBundle):
    """Best-effort halt of every controller."""
    for transport in bundle.transports.values():
        try:
            transport.command(Command.stop())
        except Exception:
            pass


def execute(
    compiled: CompiledRun,
    bundle: DeviceBundle,
    graph_initial_volumes: Optional[Dict[str, float]] = None,
    time_scale: float = 1.0,
    max_wait_s: Optional[float] = None,
    sleep_fn: Callable[[float], None] = time.sleep,
    logger: Optional[Callable[[str], None]] = None,
) -> RunResult:
    """Run compiled operations.

    Parameters
    ----------
    time_scale:
        Multiplier applied to every ``wait``. ``1.0`` runs in real time;
        ``0.0`` skips waits entirely (used for fast simulation/validation).
    max_wait_s:
        Optional cap on any single wait, handy for demos of long procedures.
    """
    log: List[str] = []

    def emit(msg: str):
        log.append(msg)
        if logger:
            logger(msg)

    state = _State(graph_initial_volumes or {})
    result = RunResult(protocol_name=compiled.protocol_name, final_volumes=dict(state.volumes))

    for warning in compiled.warnings:
        emit(f"WARNING: {warning}")

    start = time.time()
    bundle.open_all()
    try:
        for i, op in enumerate(compiled.operations, 1):
            emit(f"[{i:>3}/{len(compiled.operations)}] {op.description}")
            _run_op(op, bundle, state, emit, time_scale, max_wait_s, sleep_fn)
            result.operations_run += 1
    except Exception as exc:  # noqa: BLE001 - we want to stop hardware on *any* error
        result.aborted = True
        result.error = str(exc)
        emit(f"ABORT: {exc} -- sending emergency STOP")
        _emergency_stop(bundle)
        raise
    finally:
        result.elapsed_s = time.time() - start
        result.final_volumes = dict(state.volumes)
        result.log = log
        bundle.close_all()

    return result


def _run_op(op: Operation, bundle: DeviceBundle, state, emit, time_scale, max_wait_s, sleep_fn):
    kind = op.kind
    if kind == "comment":
        return
    if kind == "pump":
        pump = bundle.pumps[op.device_id]
        pump.dispense(op.volume_ml, op.rate_ml_s)
        state.apply(op.volume_deltas)
        return
    if kind == "stir":
        bundle.stirrers[op.device_id].start(op.rpm)
        return
    if kind == "stop_stir":
        bundle.stirrers[op.device_id].stop()
        return
    if kind == "heat":
        bundle.heaters[op.device_id].set_temperature(op.temp_c)
        return
    if kind == "heat_off":
        bundle.heaters[op.device_id].off()
        return
    if kind == "home":
        bundle.pumps[op.device_id].home()
        return
    if kind == "wait":
        seconds = (op.time_s or 0.0) * time_scale
        if max_wait_s is not None:
            seconds = min(seconds, max_wait_s)
        if seconds > 0:
            sleep_fn(seconds)
        return
    raise ValueError(f"unknown operation kind: {kind!r}")
