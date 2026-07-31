"""Transports that talk to a real ESP32 controller.

Two are provided:

* :class:`SerialTransport` — USB / UART, requires ``pyserial`` (``pip install
  labforge[serial]``).
* :class:`MqttTransport` — WiFi via an MQTT broker, requires ``paho-mqtt``
  (``pip install labforge[mqtt]``).

Both are imported lazily so the core suite has zero hard dependencies and the
simulator path always works.
"""

from __future__ import annotations

import threading
import time
from typing import Optional

from labforge.devices.base import Transport
from labforge.transport.protocol import ProtocolError


class SerialTransport(Transport):
    """Line-oriented serial transport to an ESP32 running the LabForge firmware."""

    def __init__(self, port: str, baud: int = 115200, timeout: float = 10.0):
        self.port = port
        self.baud = baud
        self.timeout = timeout
        self._serial = None

    def open(self) -> None:
        try:
            import serial  # type: ignore
        except ImportError as exc:  # pragma: no cover - env dependent
            raise ImportError(
                "SerialTransport needs pyserial. Install with: pip install 'labforge[serial]'"
            ) from exc
        self._serial = serial.Serial(self.port, self.baud, timeout=self.timeout)
        # Give the board time to reset after opening the port, then flush banner.
        time.sleep(2.0)
        self._serial.reset_input_buffer()

    def close(self) -> None:
        if self._serial is not None:
            self._serial.close()
            self._serial = None

    def _write_read(self, line: str) -> str:
        if self._serial is None:
            self.open()
        self._serial.write(line.encode("ascii"))
        self._serial.flush()
        raw = self._serial.readline()
        if not raw:
            raise ProtocolError(f"timeout waiting for response to {line.strip()!r}")
        return raw.decode("ascii", errors="replace").strip()


class MqttTransport(Transport):
    """Request/response over MQTT for WiFi-connected ESP32 controllers.

    Publishes commands to ``<base>/cmd`` and waits for a reply on
    ``<base>/resp``. Simple correlation: one outstanding command at a time,
    which matches the single-threaded executor.
    """

    def __init__(
        self,
        host: str,
        base_topic: str,
        port: int = 1883,
        timeout: float = 10.0,
        client_id: Optional[str] = None,
    ):
        self.host = host
        self.port = port
        self.base_topic = base_topic.rstrip("/")
        self.timeout = timeout
        self.client_id = client_id or "labforge-host"
        self._client = None
        self._resp = None
        self._event = threading.Event()

    def open(self) -> None:
        try:
            import paho.mqtt.client as mqtt  # type: ignore
        except ImportError as exc:  # pragma: no cover - env dependent
            raise ImportError(
                "MqttTransport needs paho-mqtt. Install with: pip install 'labforge[mqtt]'"
            ) from exc
        self._client = mqtt.Client(client_id=self.client_id)
        self._client.on_message = self._on_message
        self._client.connect(self.host, self.port)
        self._client.subscribe(f"{self.base_topic}/resp")
        self._client.loop_start()

    def close(self) -> None:
        if self._client is not None:
            self._client.loop_stop()
            self._client.disconnect()
            self._client = None

    def _on_message(self, _client, _userdata, msg):
        self._resp = msg.payload.decode("ascii", errors="replace").strip()
        self._event.set()

    def _write_read(self, line: str) -> str:
        if self._client is None:
            self.open()
        self._event.clear()
        self._resp = None
        self._client.publish(f"{self.base_topic}/cmd", line.strip())
        if not self._event.wait(self.timeout):
            raise ProtocolError(f"timeout waiting for MQTT response to {line.strip()!r}")
        return self._resp or ""
