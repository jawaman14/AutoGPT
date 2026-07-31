"""An in-process transport that emulates the ESP32 firmware.

This lets an entire procedure run — and be validated — with no hardware. It
implements the same line protocol as the firmware and keeps a little internal
state (stepper positions, stir speeds, heater setpoints) so reads return
plausible values.
"""

from __future__ import annotations

from typing import Callable, List, Optional

from labforge.devices.base import Transport

AMBIENT_C = 22.0


class SimulatedTransport(Transport):
    """Emulates one ESP32 controller entirely in Python."""

    def __init__(self, controller_id: str = "sim", on_line: Optional[Callable[[str], None]] = None):
        self.controller_id = controller_id
        self._on_line = on_line
        self._open = False
        # channel -> state
        self.pump_position: dict = {}
        self.stir_rpm: dict = {}
        self.heat_setpoint: dict = {}
        self.log: List[str] = []

    def open(self) -> None:
        self._open = True

    def close(self) -> None:
        self._open = False

    def _emit(self, line: str) -> None:
        self.log.append(line)
        if self._on_line:
            self._on_line(f"[{self.controller_id}] {line}")

    def _write_read(self, line: str) -> str:
        if not self._open:
            self.open()
        text = line.strip()
        self._emit(f"-> {text}")
        resp = self._dispatch(text)
        self._emit(f"<- {resp}")
        return resp

    def _dispatch(self, text: str) -> str:
        if not text:
            return "ERR empty"
        parts = text.split()
        verb = parts[0].upper()
        args = parts[1:]
        try:
            if verb == "PING":
                return "OK PONG"
            if verb == "INFO":
                return f"OK labforge-sim {self.controller_id}"
            if verb == "STOP":
                self.stir_rpm.clear()
                self.heat_setpoint.clear()
                return "OK"
            if verb == "PUMP":
                ch, steps, _rate = int(args[0]), int(args[1]), int(args[2])
                self.pump_position[ch] = self.pump_position.get(ch, 0) + steps
                return "OK"
            if verb == "HOME":
                ch = int(args[0])
                self.pump_position[ch] = 0
                return "OK"
            if verb == "STIR":
                ch, rpm = int(args[0]), int(args[1])
                if rpm <= 0:
                    self.stir_rpm.pop(ch, None)
                else:
                    self.stir_rpm[ch] = rpm
                return "OK"
            if verb == "HEAT":
                ch = int(args[0])
                if args[1].upper() == "OFF":
                    self.heat_setpoint.pop(ch, None)
                else:
                    self.heat_setpoint[ch] = float(args[1])
                return "OK"
            if verb == "TEMP":
                ch = int(args[0])
                # Report the setpoint if heating, else ambient (with tiny noise-free bias).
                return f"OK {self.heat_setpoint.get(ch, AMBIENT_C):.2f}"
        except (IndexError, ValueError):
            return "ERR bad args"
        return f"ERR unknown verb {verb}"
