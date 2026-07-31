"""Transport abstraction and high-level actuator devices.

A :class:`Transport` is anything that can carry a :class:`Command` to a
controller and return a :class:`Response` — a real serial link, an MQTT bridge,
or the in-process simulator. The actuator classes (pump/stirrer/heater/sensor)
wrap a transport + calibration and expose chemistry-friendly methods
(``dispense(ml)``, ``set_temperature(c)`` …). This keeps the executor free of
any wire-protocol detail.
"""

from __future__ import annotations

import abc
from typing import Optional

from labforge.graph.hardware_graph import Heater, Pump, Sensor, Stirrer
from labforge.transport.protocol import Command, Response, parse_response


class Transport(abc.ABC):
    """Carries commands to one controller and returns parsed responses."""

    @abc.abstractmethod
    def open(self) -> None:  # pragma: no cover - trivial in subclasses
        ...

    @abc.abstractmethod
    def close(self) -> None:  # pragma: no cover - trivial in subclasses
        ...

    @abc.abstractmethod
    def _write_read(self, line: str) -> str:
        """Send a raw line, return the raw response line."""

    def command(self, command: Command) -> Response:
        """Send a :class:`Command`, return the parsed :class:`Response`."""
        raw = self._write_read(command.encode())
        return parse_response(raw)

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, *exc):
        self.close()


class PumpDevice:
    """A syringe or peristaltic pump on a given controller channel."""

    def __init__(self, transport: Transport, spec: Pump):
        self.transport = transport
        self.spec = spec

    @property
    def id(self) -> str:
        return self.spec.id

    def dispense(self, volume_ml: float, rate_ml_s: Optional[float] = None) -> Response:
        """Move ``volume_ml`` from source to dest (positive = dispense)."""
        steps = self.spec.steps_for_ml(volume_ml)
        rate = self.spec.rate_pps(rate_ml_s)
        cmd = Command.pump(self.spec.channel, steps, rate)
        return self.transport.command(cmd).raise_for_status(f"pump {self.id} dispense")

    def withdraw(self, volume_ml: float, rate_ml_s: Optional[float] = None) -> Response:
        """Move ``volume_ml`` in the reverse direction (negative steps)."""
        steps = -self.spec.steps_for_ml(volume_ml)
        rate = self.spec.rate_pps(rate_ml_s)
        cmd = Command.pump(self.spec.channel, steps, rate)
        return self.transport.command(cmd).raise_for_status(f"pump {self.id} withdraw")

    def home(self) -> Response:
        return self.transport.command(Command.home(self.spec.channel)).raise_for_status(
            f"pump {self.id} home"
        )


class StirrerDevice:
    """A magnetic/overhead stirrer."""

    def __init__(self, transport: Transport, spec: Stirrer):
        self.transport = transport
        self.spec = spec

    @property
    def id(self) -> str:
        return self.spec.id

    def start(self, rpm: Optional[float] = None) -> Response:
        target = self.spec.default_rpm if rpm is None else min(rpm, self.spec.max_rpm)
        return self.transport.command(
            Command.stir(self.spec.channel, target)
        ).raise_for_status(f"stirrer {self.id}")

    def stop(self) -> Response:
        return self.transport.command(
            Command.stir(self.spec.channel, 0)
        ).raise_for_status(f"stirrer {self.id}")


class HeaterDevice:
    """A closed-loop heater/chiller with an optional bound temperature sensor."""

    def __init__(self, transport: Transport, spec: Heater):
        self.transport = transport
        self.spec = spec

    @property
    def id(self) -> str:
        return self.spec.id

    def set_temperature(self, temp_c: float) -> Response:
        if temp_c > self.spec.max_temp_c:
            raise ValueError(
                f"heater {self.id}: setpoint {temp_c} °C exceeds max "
                f"{self.spec.max_temp_c} °C"
            )
        return self.transport.command(
            Command.heat(self.spec.channel, temp_c)
        ).raise_for_status(f"heater {self.id}")

    def off(self) -> Response:
        return self.transport.command(
            Command.heat(self.spec.channel, None)
        ).raise_for_status(f"heater {self.id} off")

    def read_temperature(self) -> Optional[float]:
        if self.spec.sensor_channel is None:
            return None
        resp = self.transport.command(
            Command.temp(self.spec.sensor_channel)
        ).raise_for_status(f"heater {self.id} temp")
        return resp.as_float()


class SensorDevice:
    """A standalone sensor (temperature, etc.)."""

    def __init__(self, transport: Transport, spec: Sensor):
        self.transport = transport
        self.spec = spec

    @property
    def id(self) -> str:
        return self.spec.id

    def read(self) -> float:
        resp = self.transport.command(
            Command.temp(self.spec.channel)
        ).raise_for_status(f"sensor {self.id}")
        return resp.as_float()
