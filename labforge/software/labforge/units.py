"""Tiny unit parser for the XDL value strings LabForge understands.

XDL attributes carry human units, e.g. ``volume="10 mL"``, ``time="2 h"``,
``temp="50 °C"``, ``stir_speed="300 RPM"``. We normalise everything to SI-ish
base units used throughout the suite:

* volume  -> millilitres (mL)
* time    -> seconds (s)
* temp    -> degrees Celsius (°C)
* speed   -> revolutions per minute (RPM)

The parser is deliberately forgiving about spacing and case but strict about
unrecognised units, because silently guessing a unit in a chemistry context is
a safety hazard.
"""

from __future__ import annotations

import re

__all__ = [
    "UnitError",
    "parse_volume_ml",
    "parse_time_s",
    "parse_temp_c",
    "parse_speed_rpm",
]


class UnitError(ValueError):
    """Raised when a value string cannot be parsed into the expected unit."""


_NUMBER = r"(-?\d+(?:\.\d+)?)"

_VOLUME_TO_ML = {
    "l": 1000.0,
    "ml": 1.0,
    "cl": 10.0,
    "dl": 100.0,
    "ul": 0.001,
    "µl": 0.001,
    "μl": 0.001,
    "cc": 1.0,
}

_TIME_TO_S = {
    "s": 1.0,
    "sec": 1.0,
    "secs": 1.0,
    "second": 1.0,
    "seconds": 1.0,
    "min": 60.0,
    "mins": 60.0,
    "minute": 60.0,
    "minutes": 60.0,
    "h": 3600.0,
    "hr": 3600.0,
    "hrs": 3600.0,
    "hour": 3600.0,
    "hours": 3600.0,
    "d": 86400.0,
    "day": 86400.0,
    "days": 86400.0,
}


def _split(value, kind):
    if value is None:
        raise UnitError(f"missing {kind} value")
    text = str(value).strip()
    m = re.fullmatch(_NUMBER + r"\s*(.*)", text)
    if not m:
        raise UnitError(f"cannot parse {kind} value {value!r}")
    number = float(m.group(1))
    unit = m.group(2).strip().lower()
    return number, unit


def parse_volume_ml(value):
    """Parse a volume string (e.g. ``"10 mL"``) into millilitres."""
    number, unit = _split(value, "volume")
    if unit == "":
        raise UnitError(f"volume {value!r} is missing a unit (e.g. 'mL')")
    if unit not in _VOLUME_TO_ML:
        raise UnitError(f"unknown volume unit in {value!r}")
    return number * _VOLUME_TO_ML[unit]


def parse_time_s(value):
    """Parse a duration string (e.g. ``"2 h"``) into seconds."""
    number, unit = _split(value, "time")
    if unit == "":
        raise UnitError(f"time {value!r} is missing a unit (e.g. 's', 'min', 'h')")
    if unit not in _TIME_TO_S:
        raise UnitError(f"unknown time unit in {value!r}")
    return number * _TIME_TO_S[unit]


def parse_temp_c(value):
    """Parse a temperature string (e.g. ``"50 °C"``) into degrees Celsius."""
    number, unit = _split(value, "temperature")
    unit = unit.replace("°", "").replace("deg", "").strip()
    if unit in ("", "c", "celsius"):
        return number
    if unit in ("k", "kelvin"):
        return number - 273.15
    if unit in ("f", "fahrenheit"):
        return (number - 32.0) * 5.0 / 9.0
    raise UnitError(f"unknown temperature unit in {value!r}")


def parse_speed_rpm(value):
    """Parse a stir-speed string (e.g. ``"300 RPM"``) into RPM."""
    number, unit = _split(value, "speed")
    unit = unit.replace("/", "").replace("per", "")
    if unit in ("", "rpm", "revmin", "r"):
        return number
    raise UnitError(f"unknown stir-speed unit in {value!r}")
