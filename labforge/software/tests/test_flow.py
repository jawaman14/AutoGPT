import os

from labforge.devices.registry import build_devices
from labforge.executor.compiler import CompileError, compile_protocol
from labforge.executor.runtime import execute
from labforge.graph.hardware_graph import HardwareGraph
from labforge.protocol.xdl_parser import parse_xdl
from labforge.synthesis.methods import residence_time_min
from labforge import units

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FLOW_RIG = os.path.join(REPO_ROOT, "examples", "graphs", "5htp_flow_rig.json")


def test_flowrate_units():
    assert units.parse_flowrate_ml_min("0.5 mL/min") == 0.5
    assert units.parse_flowrate_ml_min("30 mL/h") == 0.5
    assert units.parse_flowrate_ml_min("500 uL/min") == 0.5


def test_residence_time_helper():
    assert residence_time_min(10.0, 0.5) == 20.0


def test_flow_reactor_passthrough_does_not_accumulate():
    graph = HardwareGraph.load(FLOW_RIG)
    xml = """
    <Synthesis>
      <Procedure>
        <HeatChill vessel="flow_reactor" temp="45 C"/>
        <Add reagent="serine_feed" vessel="flow_reactor" volume="10 mL" flow_rate="0.25 mL/min"/>
        <Add reagent="hydroxyindole_feed" vessel="flow_reactor" volume="10 mL" flow_rate="0.5 mL/min"/>
      </Procedure>
    </Synthesis>
    """
    compiled = compile_protocol(parse_xdl(xml), graph)
    # Reactor is pass-through: liquid ends up in the collection vessel.
    assert compiled.final_volumes["flow_reactor"] == 0.0
    assert compiled.final_volumes["product"] == 20.0
    # A residence-time note is emitted for each flow addition.
    assert any("residence" in n for n in compiled.notes)


def test_flow_delivery_time_from_flowrate():
    graph = HardwareGraph.load(FLOW_RIG)
    xml = """
    <Synthesis><Procedure>
      <Add reagent="serine_feed" vessel="flow_reactor" volume="10 mL" flow_rate="1 mL/min"/>
    </Procedure></Synthesis>
    """
    compiled = compile_protocol(parse_xdl(xml), graph)
    pump_ops = [op for op in compiled.operations if op.kind == "pump"]
    assert len(pump_ops) == 1
    # 10 mL at 1 mL/min = 10 min = 600 s.
    assert pump_ops[0].time_s == 600.0
    # rate is mL/s.
    assert abs(pump_ops[0].rate_ml_s - (1.0 / 60.0)) < 1e-9


def test_flow_run_executes():
    graph = HardwareGraph.load(FLOW_RIG)
    xml = """
    <Synthesis><Procedure>
      <HeatChill vessel="flow_reactor" temp="45 C"/>
      <Add reagent="serine_feed" vessel="flow_reactor" volume="10 mL" flow_rate="0.25 mL/min"/>
      <Add reagent="hydroxyindole_feed" vessel="flow_reactor" volume="10 mL" flow_rate="0.25 mL/min"/>
    </Procedure></Synthesis>
    """
    compiled = compile_protocol(parse_xdl(xml), graph)
    bundle = build_devices(graph, simulate=True)
    result = execute(
        compiled, bundle,
        graph_initial_volumes={v.id: v.initial_volume_ml for v in graph.vessels.values()},
        time_scale=0.0,
    )
    assert not result.aborted
    assert result.final_volumes["product"] == 20.0


def test_flow_reactor_no_overflow_but_collection_can(demo_graph):
    # Product capped small -> overflow should be caught in the collection vessel.
    data = {
        "name": "tiny",
        "controllers": [{"id": "c", "transport": "simulator"}],
        "vessels": [
            {"id": "rx", "kind": "flow_reactor", "max_volume_ml": 5,
             "passthrough": True, "outlet": "coll"},
            {"id": "coll", "max_volume_ml": 8},
        ],
        "reagents": [{"id": "a", "source": "stock_a"}],
        "pumps": [{"id": "p", "controller": "c", "channel": 0,
                   "source": "stock_a", "dest": "rx",
                   "syringe_volume_ml": 25, "steps_per_ml": 100}],
    }
    graph = HardwareGraph.from_dict(data)
    xml = ('<Synthesis><Procedure>'
           '<Add reagent="a" vessel="rx" volume="10 mL" flow_rate="1 mL/min"/>'
           '</Procedure></Synthesis>')
    import pytest
    with pytest.raises(CompileError, match="overflow"):
        compile_protocol(parse_xdl(xml), graph)
