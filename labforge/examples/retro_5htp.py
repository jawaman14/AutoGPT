#!/usr/bin/env python3
"""Retrosynthesis + batch-vs-flow worked example: L-5-hydroxytryptophan (5-HTP).

Running this script:

  1. prints the retrosynthetic tree for 5-HTP and enumerates the routes,
  2. shows the batch-vs-flow trade-offs,
  3. generates runnable XDL for the executable (enzymatic) route in BOTH batch
     and flow modes, writing them into examples/protocols/, and
  4. simulates each against its rig (no hardware needed).

    python examples/retro_5htp.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "software"))

from labforge.devices.registry import build_devices  # noqa: E402
from labforge.executor.compiler import compile_protocol  # noqa: E402
from labforge.executor.runtime import execute  # noqa: E402
from labforge.graph.hardware_graph import HardwareGraph  # noqa: E402
from labforge.protocol.xdl_parser import parse_xdl  # noqa: E402
from labforge.retro import enumerate_routes  # noqa: E402
from labforge.retro.library import enzymatic_route, five_htp_tree  # noqa: E402
from labforge.synthesis.methods import Mode, compare_table, residence_time_min  # noqa: E402

PROTO_DIR = os.path.join(HERE, "protocols")
GRAPHS = {
    Mode.BATCH: os.path.join(HERE, "graphs", "5htp_batch_rig.json"),
    Mode.FLOW: os.path.join(HERE, "graphs", "5htp_flow_rig.json"),
}
OUT = {
    Mode.BATCH: os.path.join(PROTO_DIR, "5htp_batch.xdl"),
    Mode.FLOW: os.path.join(PROTO_DIR, "5htp_flow.xdl"),
}


def banner(title):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


def show_retrosynthesis():
    banner("Retrosynthesis: L-5-hydroxytryptophan (5-HTP)")
    tree = five_htp_tree()
    print(tree.render())
    print("\nEnumerated forward routes:")
    for route in enumerate_routes(tree):
        exec_tag = "executable" if route.executable else "planning-only"
        print(f"\n[{route.name}] ({exec_tag})")
        print(route.render())


def show_methods():
    banner("Batch vs Flow")
    print(compare_table())
    # For our flow rig: 10 mL holdup, two feeds at 0.25 mL/min = 0.5 mL/min total.
    rt = residence_time_min(10.0, 0.5)
    print(f"\nFlow rig: 10 mL reactor holdup at 0.5 mL/min total => residence {rt:g} min")


def generate_and_run():
    banner("Generate XDL and simulate both modes")
    route = enzymatic_route()
    for mode in (Mode.BATCH, Mode.FLOW):
        xdl_text = route.to_xdl(mode)
        with open(OUT[mode], "w", encoding="utf-8") as fh:
            fh.write(xdl_text)
        print(f"\n--- {mode.value.upper()} ---  (written to {os.path.relpath(OUT[mode], ROOT)})")
        protocol = parse_xdl(xdl_text, name=f"5htp_{mode.value}")
        graph = HardwareGraph.load(GRAPHS[mode])
        compiled = compile_protocol(protocol, graph)
        bundle = build_devices(graph, simulate=True)
        result = execute(
            compiled,
            bundle,
            graph_initial_volumes={v.id: v.initial_volume_ml for v in graph.vessels.values()},
            time_scale=0.0,
            logger=print,
        )
        print("Final volumes:", {k: round(v, 2) for k, v in result.final_volumes.items()})


def main():
    show_retrosynthesis()
    show_methods()
    generate_and_run()
    print("\nDone. 5-HTP synthesised (in simulation) via the enzymatic route, batch and flow.")


if __name__ == "__main__":
    main()
