#!/usr/bin/env python3
"""Run the example procedures end-to-end in simulation (no hardware needed).

    python examples/run_simulation.py

Equivalent to::

    labforge simulate examples/protocols/simple_dilution.xdl \
        --graph examples/graphs/demo_rig.json
"""

import os
import sys

# Make the in-repo package importable without installing it.
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "software"))

from labforge.devices.registry import build_devices  # noqa: E402
from labforge.executor.compiler import compile_protocol  # noqa: E402
from labforge.executor.runtime import execute  # noqa: E402
from labforge.graph.hardware_graph import HardwareGraph  # noqa: E402
from labforge.protocol.xdl_parser import parse_xdl_file  # noqa: E402

GRAPH = os.path.join(HERE, "graphs", "demo_rig.json")
PROTOCOLS = [
    os.path.join(HERE, "protocols", "simple_dilution.xdl"),
    os.path.join(HERE, "protocols", "acid_base_titration.xdl"),
]


def run(xdl_path, graph):
    print("=" * 70)
    protocol = parse_xdl_file(xdl_path)
    print(protocol.describe())
    compiled = compile_protocol(protocol, graph)
    print("\nCompiled to", len(compiled.operations), "operations. Executing (simulated)...\n")
    bundle = build_devices(graph, simulate=True)
    result = execute(
        compiled,
        bundle,
        graph_initial_volumes={v.id: v.initial_volume_ml for v in graph.vessels.values()},
        time_scale=0.0,  # skip real waits
        logger=print,
    )
    print("\nFinal vessel volumes:")
    for vessel, vol in result.final_volumes.items():
        print(f"  {vessel}: {vol:g} mL")
    print()


def main():
    graph = HardwareGraph.load(GRAPH)
    for xdl in PROTOCOLS:
        run(xdl, graph)
    print("All example procedures completed in simulation.")


if __name__ == "__main__":
    main()
