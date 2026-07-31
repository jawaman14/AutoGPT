import os

import pytest

from labforge.protocol import steps as S
from labforge.protocol.xdl_parser import XDLParseError, parse_xdl, parse_xdl_file

MINIMAL = """
<Synthesis name="demo">
  <Hardware><Component id="reactor" type="reactor"/></Hardware>
  <Reagents><Reagent id="water" name="water" smiles="O"/></Reagents>
  <Procedure>
    <Add reagent="water" vessel="reactor" volume="10 mL"/>
    <Stir vessel="reactor" time="30 s" stir_speed="300 RPM"/>
  </Procedure>
</Synthesis>
"""


def test_parse_minimal():
    proto = parse_xdl(MINIMAL)
    assert proto.name == "demo"
    assert len(proto.hardware) == 1
    assert "water" in proto.reagents
    assert proto.reagents["water"].smiles == "O"
    assert len(proto.steps) == 2
    add = proto.steps[0]
    assert isinstance(add, S.Add)
    assert add.volume_ml == 10.0
    stir = proto.steps[1]
    assert isinstance(stir, S.Stir)
    assert stir.time_s == 30.0
    assert stir.speed_rpm == 300.0


def test_unsupported_step_preserved():
    xml = """
    <Synthesis>
      <Procedure><Filter vessel="reactor"/></Procedure>
    </Synthesis>
    """
    proto = parse_xdl(xml)
    assert len(proto.unsupported_steps()) == 1
    assert proto.unsupported_steps()[0].xdl_name == "Filter"


def test_xdl_wrapper_and_groups():
    xml = """
    <XDL>
      <Synthesis>
        <Procedure>
          <Prep><Add reagent="water" vessel="reactor" volume="5 mL"/></Prep>
          <Reaction><Wait time="10 s"/></Reaction>
        </Procedure>
      </Synthesis>
    </XDL>
    """
    proto = parse_xdl(xml)
    assert len(proto.steps) == 2


def test_empty_procedure_raises():
    with pytest.raises(XDLParseError):
        parse_xdl("<Synthesis><Procedure></Procedure></Synthesis>")


def test_invalid_xml_raises():
    with pytest.raises(XDLParseError):
        parse_xdl("<Synthesis><Procedure>")


def test_parse_example_files(examples_dir):
    for name in ("simple_dilution.xdl", "acid_base_titration.xdl"):
        proto = parse_xdl_file(os.path.join(examples_dir, "protocols", name))
        assert proto.steps
        assert not proto.unsupported_steps()
