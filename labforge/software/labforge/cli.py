"""``labforge`` command-line interface.

Subcommands
-----------
``describe``   parse an XDL file and print the human-readable procedure.
``validate``   parse + compile against a hardware graph (no execution).
``simulate``   run the procedure against the built-in simulator (no hardware).
``run``        execute on real hardware (guarded by ``--i-understand``).
``devices``    list the actuators declared in a hardware graph.
"""

from __future__ import annotations

import argparse
import sys
from typing import Optional

from labforge.devices.registry import build_devices
from labforge.executor.compiler import CompileError, compile_protocol
from labforge.executor.runtime import execute
from labforge.graph.hardware_graph import GraphError, HardwareGraph
from labforge.protocol.xdl_parser import XDLParseError, parse_xdl_file


def _load(xdl_path: str, graph_path: Optional[str]):
    protocol = parse_xdl_file(xdl_path)
    graph = HardwareGraph.load(graph_path) if graph_path else None
    return protocol, graph


def _initial_volumes(graph: HardwareGraph):
    return {v.id: v.initial_volume_ml for v in graph.vessels.values()}


def cmd_describe(args) -> int:
    protocol = parse_xdl_file(args.xdl)
    print(protocol.describe())
    if protocol.reagents:
        print("\nReagents:")
        for r in protocol.reagents.values():
            extra = f" ({r.smiles})" if r.smiles else ""
            print(f"  - {r.id}{extra}")
    return 0


def cmd_validate(args) -> int:
    protocol, graph = _load(args.xdl, args.graph)
    compiled = compile_protocol(protocol, graph)
    print(compiled.describe())
    for w in compiled.warnings:
        print(f"WARNING: {w}")
    print("\nProjected final volumes:")
    for vessel, vol in compiled.final_volumes.items():
        print(f"  {vessel}: {vol:g} mL")
    print(f"\nEstimated procedure time: {compiled.total_time_s():g} s")
    print("OK: procedure compiles cleanly.")
    return 0


def cmd_simulate(args) -> int:
    protocol, graph = _load(args.xdl, args.graph)
    compiled = compile_protocol(protocol, graph)
    print(compiled.describe())
    print("\n--- simulated run ---")
    bundle = build_devices(
        graph,
        simulate=True,
        on_line=(print if args.verbose else None),
    )
    result = execute(
        compiled,
        bundle,
        graph_initial_volumes=_initial_volumes(graph),
        time_scale=0.0 if not args.realtime else 1.0,
        logger=print,
    )
    print("\n--- result ---")
    print(f"operations run: {result.operations_run}")
    for vessel, vol in result.final_volumes.items():
        print(f"  {vessel}: {vol:g} mL")
    return 0


def cmd_run(args) -> int:
    protocol, graph = _load(args.xdl, args.graph)
    compiled = compile_protocol(protocol, graph)
    print(compiled.describe())
    if not args.i_understand:
        print(
            "\nREFUSING to drive real hardware without acknowledgement.\n"
            "Re-run with --i-understand once you have confirmed reagents, tubing,\n"
            "fume extraction and PPE are correct. See docs/safety.md.",
            file=sys.stderr,
        )
        return 2

    overrides = {}
    if args.port:
        # Apply the port to every serial controller in the graph.
        for c in graph.controllers.values():
            if c.transport == "serial":
                overrides[c.id] = {"port": args.port}

    print("\n--- LIVE run on hardware ---")
    bundle = build_devices(graph, simulate=False, overrides=overrides)
    result = execute(
        compiled,
        bundle,
        graph_initial_volumes=_initial_volumes(graph),
        time_scale=1.0,
        max_wait_s=args.max_wait,
        logger=print,
    )
    print("\n--- result ---")
    print(f"operations run: {result.operations_run}, elapsed {result.elapsed_s:g} s")
    return 0 if not result.aborted else 1


def cmd_devices(args) -> int:
    graph = HardwareGraph.load(args.graph)
    print(f"Hardware graph: {graph.name}")
    print(f"  controllers: {', '.join(graph.controllers) or '(none)'}")
    print("  pumps:")
    for p in graph.pumps.values():
        print(
            f"    - {p.id}: {p.kind}, {p.source} -> {p.dest}, "
            f"{p.steps_per_ml:g} steps/mL on {p.controller}#{p.channel}"
        )
    print("  stirrers:")
    for s in graph.stirrers.values():
        print(f"    - {s.id}: vessel {s.vessel} on {s.controller}#{s.channel}")
    print("  heaters:")
    for h in graph.heaters.values():
        print(f"    - {h.id}: vessel {h.vessel} on {h.controller}#{h.channel}")
    print("  vessels:")
    for v in graph.vessels.values():
        print(f"    - {v.id}: {v.kind}, max {v.max_volume_ml:g} mL")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="labforge",
        description="XDL-native, ESP32-driven, 3D-printable lab automation.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("describe", help="parse and print an XDL procedure")
    p.add_argument("xdl")
    p.set_defaults(func=cmd_describe)

    p = sub.add_parser("validate", help="compile a procedure against a graph (no run)")
    p.add_argument("xdl")
    p.add_argument("--graph", required=True, help="hardware graph JSON")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("simulate", help="run against the built-in simulator")
    p.add_argument("xdl")
    p.add_argument("--graph", required=True, help="hardware graph JSON")
    p.add_argument("--verbose", action="store_true", help="show wire-level traffic")
    p.add_argument("--realtime", action="store_true", help="honour real wait times")
    p.set_defaults(func=cmd_simulate)

    p = sub.add_parser("run", help="execute on real hardware")
    p.add_argument("xdl")
    p.add_argument("--graph", required=True, help="hardware graph JSON")
    p.add_argument("--port", help="serial port override (e.g. /dev/ttyUSB0)")
    p.add_argument("--max-wait", dest="max_wait", type=float, default=None,
                   help="cap any single wait to this many seconds")
    p.add_argument("--i-understand", dest="i_understand", action="store_true",
                   help="acknowledge the safety notice and drive hardware")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("devices", help="list actuators in a hardware graph")
    p.add_argument("--graph", required=True)
    p.set_defaults(func=cmd_devices)

    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (XDLParseError, GraphError, CompileError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except FileNotFoundError as exc:
        print(f"error: file not found: {exc.filename}", file=sys.stderr)
        return 1


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
