"""The hardware graph: how vessels, reagents and actuators are physically wired.

This is LabForge's analogue of the Chemputer's GraphML connectivity file. It
declares, in plain JSON:

* **controllers** — one or more ESP32 boards and how to reach them.
* **pumps** — each pump moves fluid from a fixed ``source`` node to a fixed
  ``dest`` node (honest to how small rigs are actually tubed), on a given
  controller ``channel``, with a calibration (``steps_per_ml``).
* **stirrers / heaters / sensors** — bound to a vessel and a controller channel.
* **vessels** — reactors, flasks, waste, with volume limits and starting volume.
* **reagents** — a reagent id mapped to the source node its stock lives on.

The compiler resolves each XDL step against this graph: e.g. ``Add water to
reactor`` becomes "run the pump whose source is the water stock and whose dest
is the reactor".

Example (see ``examples/graphs/demo_rig.json``)::

    {
      "name": "demo_rig",
      "controllers": [{"id": "esp32-0", "transport": "serial"}],
      "vessels": [
        {"id": "reactor", "max_volume_ml": 50},
        {"id": "waste", "max_volume_ml": 1000}
      ],
      "reagents": [{"id": "water", "source": "stock_water"}],
      "pumps": [
        {"id": "p_water", "kind": "syringe", "controller": "esp32-0",
         "channel": 0, "source": "stock_water", "dest": "reactor",
         "syringe_volume_ml": 10, "steps_per_ml": 1600, "max_rate_ml_s": 1.0}
      ],
      "stirrers": [{"id": "s0", "controller": "esp32-0", "channel": 0, "vessel": "reactor"}]
    }
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Dict, List, Optional


class GraphError(ValueError):
    """Raised when a hardware graph is inconsistent or missing references."""


@dataclass
class Controller:
    id: str
    transport: str = "simulator"  # "serial" | "mqtt" | "simulator"
    port: Optional[str] = None
    baud: int = 115200
    host: Optional[str] = None
    topic: Optional[str] = None
    attrs: dict = field(default_factory=dict)


@dataclass
class Vessel:
    id: str
    kind: str = "reactor"
    max_volume_ml: float = 100.0
    initial_volume_ml: float = 0.0
    # Flow-synthesis: a pass-through vessel (e.g. a continuous flow reactor or
    # mixing tee) does not accumulate liquid. Its ``max_volume_ml`` is the
    # internal holdup used for residence-time; incoming volume is forwarded to
    # ``outlet`` for accounting.
    passthrough: bool = False
    outlet: Optional[str] = None

    @property
    def is_flow_reactor(self) -> bool:
        return self.kind == "flow_reactor" or self.passthrough


@dataclass
class Pump:
    id: str
    controller: str
    channel: int
    source: str
    dest: str
    kind: str = "syringe"  # "syringe" | "peristaltic"
    syringe_volume_ml: float = 10.0
    steps_per_ml: float = 1600.0
    max_rate_ml_s: float = 1.0

    def steps_for_ml(self, volume_ml: float) -> int:
        return int(round(volume_ml * self.steps_per_ml))

    def rate_pps(self, rate_ml_s: Optional[float]) -> int:
        """Steps-per-second for a requested mL/s rate, clamped to the pump max."""
        r = self.max_rate_ml_s if rate_ml_s is None else min(rate_ml_s, self.max_rate_ml_s)
        r = max(r, 1e-6)
        return max(1, int(round(r * self.steps_per_ml)))


@dataclass
class Stirrer:
    id: str
    controller: str
    channel: int
    vessel: str
    default_rpm: float = 300.0
    max_rpm: float = 1500.0


@dataclass
class Heater:
    id: str
    controller: str
    channel: int
    vessel: str
    sensor_channel: Optional[int] = None
    max_temp_c: float = 150.0


@dataclass
class Sensor:
    id: str
    controller: str
    channel: int
    vessel: str
    quantity: str = "temperature"


class HardwareGraph:
    """In-memory view of a hardware graph with lookup + validation helpers."""

    def __init__(
        self,
        name: str = "rig",
        controllers=None,
        vessels=None,
        pumps=None,
        stirrers=None,
        heaters=None,
        sensors=None,
        reagents=None,
    ):
        self.name = name
        self.controllers: Dict[str, Controller] = {c.id: c for c in (controllers or [])}
        self.vessels: Dict[str, Vessel] = {v.id: v for v in (vessels or [])}
        self.pumps: Dict[str, Pump] = {p.id: p for p in (pumps or [])}
        self.stirrers: Dict[str, Stirrer] = {s.id: s for s in (stirrers or [])}
        self.heaters: Dict[str, Heater] = {h.id: h for h in (heaters or [])}
        self.sensors: Dict[str, Sensor] = {s.id: s for s in (sensors or [])}
        # reagent id -> source node id
        self.reagents: Dict[str, str] = dict(reagents or {})

    # ------------------------------------------------------------------ load
    @classmethod
    def from_dict(cls, data: dict) -> "HardwareGraph":
        def build(key, factory):
            return [factory(**item) for item in data.get(key, [])]

        reagents = {}
        for item in data.get("reagents", []):
            reagents[item["id"]] = item.get("source", item["id"])

        graph = cls(
            name=data.get("name", "rig"),
            controllers=build("controllers", Controller),
            vessels=build("vessels", Vessel),
            pumps=build("pumps", Pump),
            stirrers=build("stirrers", Stirrer),
            heaters=build("heaters", Heater),
            sensors=build("sensors", Sensor),
            reagents=reagents,
        )
        graph.validate()
        return graph

    @classmethod
    def load(cls, path) -> "HardwareGraph":
        with open(path, "r", encoding="utf-8") as fh:
            return cls.from_dict(json.load(fh))

    # ------------------------------------------------------------- lookups
    def source_for_reagent(self, reagent_id: str) -> Optional[str]:
        """Return the source node holding a reagent's stock (defaults to its id)."""
        return self.reagents.get(reagent_id, reagent_id)

    def find_pump(self, source: str, dest: str) -> Optional[Pump]:
        """Find a pump wired from ``source`` to ``dest``."""
        for pump in self.pumps.values():
            if pump.source == source and pump.dest == dest:
                return pump
        return None

    def stirrer_for(self, vessel_id: str) -> Optional[Stirrer]:
        for s in self.stirrers.values():
            if s.vessel == vessel_id:
                return s
        return None

    def heater_for(self, vessel_id: str) -> Optional[Heater]:
        for h in self.heaters.values():
            if h.vessel == vessel_id:
                return h
        return None

    def sensor_for(self, vessel_id: str, quantity: str = "temperature") -> Optional[Sensor]:
        for s in self.sensors.values():
            if s.vessel == vessel_id and s.quantity == quantity:
                return s
        return None

    def is_vessel(self, node_id: str) -> bool:
        return node_id in self.vessels

    def flow_reactor_on_route(self, source: str, dest: str) -> Optional[Vessel]:
        """Return the destination vessel if it is a flow reactor / pass-through."""
        vessel = self.vessels.get(dest)
        if vessel is not None and vessel.is_flow_reactor:
            return vessel
        return None

    # ---------------------------------------------------------- validation
    def validate(self):
        """Raise :class:`GraphError` on dangling controller/vessel references."""
        for pump in self.pumps.values():
            if pump.controller not in self.controllers:
                raise GraphError(
                    f"pump {pump.id!r} references unknown controller {pump.controller!r}"
                )
        for group, attr in (
            (self.stirrers, "vessel"),
            (self.heaters, "vessel"),
            (self.sensors, "vessel"),
        ):
            for item in group.values():
                if item.controller not in self.controllers:
                    raise GraphError(
                        f"{item.id!r} references unknown controller {item.controller!r}"
                    )
                vessel = getattr(item, attr)
                if vessel not in self.vessels:
                    raise GraphError(f"{item.id!r} references unknown vessel {vessel!r}")
        for vessel in self.vessels.values():
            if vessel.passthrough and vessel.outlet and vessel.outlet not in self.vessels:
                raise GraphError(
                    f"flow reactor {vessel.id!r} has unknown outlet {vessel.outlet!r}"
                )
        return self

    def controllers_list(self) -> List[Controller]:
        return list(self.controllers.values())
