import pytest

from labforge.executor.compiler import CompileError, compile_protocol
from labforge.protocol.xdl_parser import parse_xdl


def _proto(procedure_body):
    return parse_xdl(f"<Synthesis><Procedure>{procedure_body}</Procedure></Synthesis>")


def test_overflow_detected(demo_graph):
    # reactor max is 50 mL
    proto = _proto('<Add reagent="water" vessel="reactor" volume="60 mL"/>')
    with pytest.raises(CompileError, match="overflow"):
        compile_protocol(proto, demo_graph)


def test_underflow_detected(demo_graph):
    proto = _proto('<Transfer from_vessel="reactor" to_vessel="waste" volume="10 mL"/>')
    with pytest.raises(CompileError, match="negative|empty|not enough"):
        compile_protocol(proto, demo_graph)


def test_missing_pump_wiring(demo_graph):
    # No pump wired stock_water -> waste
    proto = _proto('<Add reagent="water" vessel="waste" volume="5 mL"/>')
    with pytest.raises(CompileError, match="no pump wired"):
        compile_protocol(proto, demo_graph)


def test_missing_stirrer(demo_graph):
    proto = _proto('<Stir vessel="waste" time="10 s"/>')
    with pytest.raises(CompileError, match="no stirrer"):
        compile_protocol(proto, demo_graph)


def test_unsupported_step_aborts(demo_graph):
    proto = _proto('<Filter vessel="reactor"/>')
    with pytest.raises(CompileError, match="cannot execute"):
        compile_protocol(proto, demo_graph)


def test_heater_over_max(demo_graph):
    proto = _proto('<HeatChill vessel="reactor" temp="200 C" time="10 s"/>')
    with pytest.raises(CompileError, match="exceeds heater max"):
        compile_protocol(proto, demo_graph)


def test_volume_tracking(demo_graph):
    proto = _proto(
        '<Add reagent="water" vessel="reactor" volume="20 mL"/>'
        '<Add reagent="hcl" vessel="reactor" volume="5 mL"/>'
        '<Transfer from_vessel="reactor" to_vessel="waste" volume="all"/>'
    )
    compiled = compile_protocol(proto, demo_graph)
    assert compiled.final_volumes["reactor"] == 0.0
    assert compiled.final_volumes["waste"] == 25.0


def test_transfer_all_uses_tracked_volume(demo_graph):
    proto = _proto(
        '<Add reagent="water" vessel="reactor" volume="12 mL"/>'
        '<Transfer from_vessel="reactor" to_vessel="waste" volume="all"/>'
    )
    compiled = compile_protocol(proto, demo_graph)
    drain_ops = [op for op in compiled.operations if op.device_id == "p_drain"]
    assert len(drain_ops) == 1
    assert drain_ops[0].volume_ml == 12.0
