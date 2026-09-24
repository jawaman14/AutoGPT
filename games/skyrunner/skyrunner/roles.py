"""Sides, roles, match modes and who is allowed to do what.

Every non-flight action in the game is a *command* issued by a role
(`Session.command(role, name, **args)`). Local menus, network clients and AI
crew all go through the same gate, so a co-pilot on another machine can do
exactly what the table below says and nothing more.
"""
from __future__ import annotations

from enum import Enum


class Side(str, Enum):
    RUNNER = "runner"
    LAW = "law"


class Role(str, Enum):
    PILOT = "pilot"
    COPILOT = "copilot"
    SPOTTER = "spotter"
    BOAT = "boat"
    CONTROLLER = "controller"
    INTERCEPTOR = "interceptor"
    CUTTER = "cutter"

    @property
    def side(self) -> Side:
        return Side.LAW if self in (Role.CONTROLLER, Role.INTERCEPTOR, Role.CUTTER) else Side.RUNNER


class Mode(str, Enum):
    SOLO = "solo"  # human pilot vs AI law
    POLICE = "police"  # human controller vs AI runners
    COOP = "coop"  # human runner crew vs AI law
    VERSUS = "versus"  # humans on both sides, AI fills gaps
    CAMPAIGN = "campaign"  # solo/co-op, chapter rules


_GROUND_OPS = {"accept_job", "drop_job", "move_item", "loadmaster", "set_fuel", "fill_ferry"}
_CREW_AIR = {"kick", "pump", "call_boat", "auto_kick"}

PERMISSIONS: dict[Role, set[str]] = {
    Role.PILOT: _GROUND_OPS | _CREW_AIR | {
        "buy_aircraft", "buy_gear", "hire_spotter", "transponder", "autopilot", "confirm", "chat",
    },
    Role.COPILOT: _GROUND_OPS | _CREW_AIR | {"hire_spotter", "chat"},
    Role.SPOTTER: {"spotter_move", "chat"},
    Role.BOAT: {"boat_goto", "chat"},
    Role.CONTROLLER: {"launch", "dispatch", "recall", "encrypt", "aerostat", "chat"},
    Role.INTERCEPTOR: {"chat"},
    Role.CUTTER: {"chat"},
}

# Roles a human can take in each mode. Everything else is AI or absent.
MODE_ROLES: dict[Mode, tuple[Role, ...]] = {
    Mode.SOLO: (Role.PILOT,),
    Mode.POLICE: (Role.CONTROLLER,),
    Mode.COOP: (Role.PILOT, Role.COPILOT, Role.SPOTTER),
    Mode.VERSUS: (Role.PILOT, Role.COPILOT, Role.SPOTTER, Role.CONTROLLER),
    Mode.CAMPAIGN: (Role.PILOT, Role.COPILOT, Role.SPOTTER),
}


def allowed(role: Role, command: str) -> bool:
    return command in PERMISSIONS.get(role, set())
