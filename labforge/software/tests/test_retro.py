import os

from labforge.executor.compiler import compile_protocol
from labforge.graph.hardware_graph import HardwareGraph
from labforge.protocol.xdl_parser import parse_xdl
from labforge.retro import enumerate_routes
from labforge.retro.library import enzymatic_route, five_htp_tree, get
from labforge.synthesis.methods import Mode

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GRAPHS = {
    Mode.BATCH: os.path.join(REPO_ROOT, "examples", "graphs", "5htp_batch_rig.json"),
    Mode.FLOW: os.path.join(REPO_ROOT, "examples", "graphs", "5htp_flow_rig.json"),
}


def test_tree_has_three_strategies():
    tree = five_htp_tree()
    assert tree.molecule.name.endswith("5-hydroxytryptophan")
    assert len(tree.disconnections) == 3


def test_enumerate_routes():
    routes = enumerate_routes(five_htp_tree())
    assert len(routes) == 3
    executable = [r for r in routes if r.executable]
    assert len(executable) == 1  # only the enzymatic route runs on this rig class


def test_get_aliases():
    assert get("5-HTP").molecule.cas == "4350-09-8"
    assert get("5htp").molecule is not None


def test_render_does_not_crash():
    tree = five_htp_tree()
    text = tree.render()
    assert "5-hydroxyindole" in text
    assert "Erlenmeyer" in text


def test_enzymatic_route_compiles_both_modes():
    route = enzymatic_route()
    assert route.modes()  # supports at least one mode
    for mode in (Mode.BATCH, Mode.FLOW):
        xdl_text = route.to_xdl(mode)
        protocol = parse_xdl(xdl_text)
        graph = HardwareGraph.load(GRAPHS[mode])
        compiled = compile_protocol(protocol, graph)
        assert compiled.operations
        # product is collected in both modes
        assert compiled.final_volumes.get("product", 0) > 0


def test_flow_route_reports_residence():
    route = enzymatic_route()
    graph = HardwareGraph.load(GRAPHS[Mode.FLOW])
    compiled = compile_protocol(parse_xdl(route.to_xdl(Mode.FLOW)), graph)
    assert any("residence" in n for n in compiled.notes)


def test_planning_only_route_refuses_xdl():
    # route-2 / route-3 are planning-only; to_xdl should raise.
    routes = enumerate_routes(five_htp_tree())
    planning = [r for r in routes if not r.executable]
    assert planning
    import pytest
    with pytest.raises(ValueError, match="no executable XDL"):
        planning[0].to_xdl(Mode.BATCH)


def test_generated_example_files_match_current_library():
    """The committed example XDL should stay in sync with the library output."""
    route = enzymatic_route()
    for mode, fname in ((Mode.BATCH, "5htp_batch.xdl"), (Mode.FLOW, "5htp_flow.xdl")):
        path = os.path.join(REPO_ROOT, "examples", "protocols", fname)
        with open(path, encoding="utf-8") as fh:
            on_disk = fh.read()
        assert on_disk == route.to_xdl(mode), f"{fname} is stale; re-run examples/retro_5htp.py"
