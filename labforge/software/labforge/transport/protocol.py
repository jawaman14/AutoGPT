"""LabForge <-> ESP32 line protocol.

A deliberately tiny, human-readable, newline-terminated ASCII protocol so it can
be driven from a serial monitor by hand while debugging. The **same grammar** is
implemented by the firmware in ``firmware/esp32``.

Host -> device (one command per line, space separated)::

    PING                         # liveness check
    PUMP <ch> <steps> <rate_pps> # move stepper: signed steps (+ = dispense)
    STIR <ch> <rpm>              # rpm 0 stops the stirrer
    HEAT <ch> <temp_c|OFF>       # setpoint for closed-loop heater, or OFF
    TEMP <ch>                    # read a temperature sensor channel
    HOME <ch>                    # home a pump axis to its endstop
    STOP                         # emergency stop: halt all actuators
    INFO                         # firmware id / capabilities

Device -> host (one response per command)::

    OK                           # generic success
    OK <payload>                 # success with data, e.g. "OK 24.6"
    ERR <message>                # failure

The host library treats any non-``OK`` first token as an error.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional


class ProtocolError(RuntimeError):
    """Raised when the device returns an error or an unparseable response."""


@dataclass(frozen=True)
class Command:
    """A single host->device command line."""

    verb: str
    args: tuple = ()

    def encode(self) -> str:
        parts = [self.verb, *[str(a) for a in self.args]]
        return " ".join(parts) + "\n"

    def __str__(self) -> str:
        return self.encode().strip()

    # -- convenience constructors ------------------------------------------
    @staticmethod
    def ping() -> "Command":
        return Command("PING")

    @staticmethod
    def info() -> "Command":
        return Command("INFO")

    @staticmethod
    def pump(channel: int, steps: int, rate_pps: int) -> "Command":
        return Command("PUMP", (int(channel), int(steps), int(rate_pps)))

    @staticmethod
    def stir(channel: int, rpm: int) -> "Command":
        return Command("STIR", (int(channel), int(round(rpm))))

    @staticmethod
    def heat(channel: int, temp_c: Optional[float]) -> "Command":
        if temp_c is None:
            return Command("HEAT", (int(channel), "OFF"))
        return Command("HEAT", (int(channel), round(float(temp_c), 2)))

    @staticmethod
    def temp(channel: int) -> "Command":
        return Command("TEMP", (int(channel),))

    @staticmethod
    def home(channel: int) -> "Command":
        return Command("HOME", (int(channel),))

    @staticmethod
    def stop() -> "Command":
        return Command("STOP")


@dataclass(frozen=True)
class Response:
    """A parsed device response."""

    ok: bool
    payload: str = ""

    @property
    def tokens(self) -> List[str]:
        return self.payload.split() if self.payload else []

    def as_float(self) -> float:
        try:
            return float(self.tokens[0])
        except (IndexError, ValueError) as exc:
            raise ProtocolError(f"expected a number, got {self.payload!r}") from exc

    def raise_for_status(self, context: str = "") -> "Response":
        if not self.ok:
            prefix = f"{context}: " if context else ""
            raise ProtocolError(f"{prefix}device error: {self.payload}")
        return self


def parse_response(line: str) -> Response:
    """Parse a raw device response line into a :class:`Response`."""
    text = (line or "").strip()
    if not text:
        raise ProtocolError("empty response from device")
    head, _, rest = text.partition(" ")
    if head.upper() == "OK":
        return Response(ok=True, payload=rest.strip())
    if head.upper() == "ERR":
        return Response(ok=False, payload=rest.strip())
    # Some firmwares echo bare data; treat a leading number as OK payload.
    return Response(ok=True, payload=text)
