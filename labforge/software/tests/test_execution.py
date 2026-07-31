import os

from labforge.devices.registry import build_devices
from labforge.executor.compiler import compile_protocol
from labforge.executor.runtime import execute
from labforge.protocol.xdl_parser import parse_xdl_file
from labforge.transport.protocol import Command, parse_response


def _init_vols(graph):
    return {v.id: v.initial_volume_ml for v in graph.vessels.values()}


def test_simulated_run_examples(demo_graph, examples_dir):
    for name in ("simple_dilution.xdl", "acid_base_titration.xdl"):
        proto = parse_xdl_file(os.path.join(examples_dir, "protocols", name))
        compiled = compile_protocol(proto, demo_graph)
        bundle = build_devices(demo_graph, simulate=True)
        result = execute(
            compiled, bundle, graph_initial_volumes=_init_vols(demo_graph), time_scale=0.0
        )
        assert result.operations_run == len(compiled.operations)
        assert not result.aborted


def test_simulator_speaks_protocol(demo_graph):
    bundle = build_devices(demo_graph, simulate=True)
    t = bundle.transports["esp32-0"]
    t.open()
    assert parse_response(t._write_read(Command.ping().encode())).payload == "PONG"
    # A pump move updates simulated stepper position.
    t._write_read(Command.pump(0, 1600, 800).encode())
    assert t.pump_position[0] == 1600
    # Heat setpoint then read it back.
    t._write_read(Command.heat(0, 42.0).encode())
    assert parse_response(t._write_read(Command.temp(0).encode())).as_float() == 42.0


def test_dilution_final_volume(demo_graph, examples_dir):
    proto = parse_xdl_file(os.path.join(examples_dir, "protocols", "simple_dilution.xdl"))
    compiled = compile_protocol(proto, demo_graph)
    bundle = build_devices(demo_graph, simulate=True)
    result = execute(
        compiled, bundle, graph_initial_volumes=_init_vols(demo_graph), time_scale=0.0
    )
    assert result.final_volumes["reactor"] == 25.0
