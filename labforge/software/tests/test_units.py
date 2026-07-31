import pytest

from labforge import units


def test_volume_units():
    assert units.parse_volume_ml("10 mL") == 10.0
    assert units.parse_volume_ml("1 L") == 1000.0
    assert units.parse_volume_ml("500 uL") == 0.5
    assert units.parse_volume_ml("2.5mL") == 2.5


def test_time_units():
    assert units.parse_time_s("30 s") == 30.0
    assert units.parse_time_s("2 min") == 120.0
    assert units.parse_time_s("1 h") == 3600.0


def test_temp_units():
    assert units.parse_temp_c("50 C") == 50.0
    assert units.parse_temp_c("50 °C") == 50.0
    assert units.parse_temp_c("323.15 K") == pytest.approx(50.0)
    assert units.parse_temp_c("122 F") == pytest.approx(50.0)


def test_speed_units():
    assert units.parse_speed_rpm("300 RPM") == 300.0
    assert units.parse_speed_rpm("300") == 300.0


def test_bad_units_raise():
    with pytest.raises(units.UnitError):
        units.parse_volume_ml("10 furlongs")
    with pytest.raises(units.UnitError):
        units.parse_volume_ml("10")  # missing unit
    with pytest.raises(units.UnitError):
        units.parse_time_s("nonsense")
