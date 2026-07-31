"""Build concrete devices + transports from a :class:`HardwareGraph`."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Dict, Optional

from labforge.devices.base import (
    HeaterDevice,
    PumpDevice,
    SensorDevice,
    StirrerDevice,
    Transport,
)
from labforge.devices.simulator import SimulatedTransport
from labforge.graph.hardware_graph import HardwareGraph


@dataclass
class DeviceBundle:
    """All live devices for a run, plus their transports."""

    transports: Dict[str, Transport] = field(default_factory=dict)
    pumps: Dict[str, PumpDevice] = field(default_factory=dict)
    stirrers: Dict[str, StirrerDevice] = field(default_factory=dict)
    heaters: Dict[str, HeaterDevice] = field(default_factory=dict)
    sensors: Dict[str, SensorDevice] = field(default_factory=dict)

    def open_all(self):
        for t in self.transports.values():
            t.open()

    def close_all(self):
        for t in self.transports.values():
            try:
                t.close()
            except Exception:
                pass


def _build_transport(controller, simulate: bool, on_line, overrides):
    if simulate or controller.transport == "simulator":
        return SimulatedTransport(controller.id, on_line=on_line)

    ov = (overrides or {}).get(controller.id, {})
    if controller.transport == "serial":
        from labforge.devices.esp32 import SerialTransport

        return SerialTransport(
            port=ov.get("port", controller.port),
            baud=ov.get("baud", controller.baud),
        )
    if controller.transport == "mqtt":
        from labforge.devices.esp32 import MqttTransport

        return MqttTransport(
            host=ov.get("host", controller.host),
            base_topic=ov.get("topic", controller.topic or controller.id),
        )
    raise ValueError(f"unknown transport {controller.transport!r} for {controller.id!r}")


def build_devices(
    graph: HardwareGraph,
    simulate: bool = True,
    on_line: Optional[Callable[[str], None]] = None,
    overrides: Optional[dict] = None,
) -> DeviceBundle:
    """Instantiate transports and devices for every actuator in the graph.

    When ``simulate`` is True (the default), every controller is backed by a
    :class:`SimulatedTransport`, so no hardware is required.
    """
    bundle = DeviceBundle()

    for controller in graph.controllers.values():
        bundle.transports[controller.id] = _build_transport(
            controller, simulate, on_line, overrides
        )

    def transport_for(controller_id):
        # Actuators may reference a controller not explicitly listed (rare);
        # fall back to a simulator so a graph never crashes at build time.
        if controller_id not in bundle.transports:
            bundle.transports[controller_id] = SimulatedTransport(
                controller_id, on_line=on_line
            )
        return bundle.transports[controller_id]

    for pump in graph.pumps.values():
        bundle.pumps[pump.id] = PumpDevice(transport_for(pump.controller), pump)
    for stirrer in graph.stirrers.values():
        bundle.stirrers[stirrer.id] = StirrerDevice(transport_for(stirrer.controller), stirrer)
    for heater in graph.heaters.values():
        bundle.heaters[heater.id] = HeaterDevice(transport_for(heater.controller), heater)
    for sensor in graph.sensors.values():
        bundle.sensors[sensor.id] = SensorDevice(transport_for(sensor.controller), sensor)

    return bundle
