import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from skyrunner.aircraft import ROSTER  # noqa: E402
from skyrunner.jsbsim_patch import build_patched_root, read_mass_data  # noqa: E402
from skyrunner.world import World  # noqa: E402


@pytest.fixture(scope="session")
def jsbsim_root(tmp_path_factory):
    return build_patched_root(list(ROSTER.values()), str(tmp_path_factory.mktemp("jsbsim")))


@pytest.fixture(scope="session")
def world():
    return World()


@pytest.fixture(scope="session")
def masses():
    return {k: read_mass_data(s.jsbsim_model) for k, s in ROSTER.items()}
