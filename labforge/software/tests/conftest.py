import json
import os

import pytest

from labforge.graph.hardware_graph import HardwareGraph

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXAMPLES = os.path.join(REPO_ROOT, "examples")


@pytest.fixture
def demo_graph_dict():
    with open(os.path.join(EXAMPLES, "graphs", "demo_rig.json")) as fh:
        return json.load(fh)


@pytest.fixture
def demo_graph(demo_graph_dict):
    return HardwareGraph.from_dict(demo_graph_dict)


@pytest.fixture
def examples_dir():
    return EXAMPLES
