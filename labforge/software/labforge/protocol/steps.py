"""XDL step objects.

Each class mirrors a step from the XDL (Chemical Description Language)
vocabulary. LabForge implements the subset that maps cleanly onto small,
pump-based, ESP32-controlled hardware. Unsupported XDL steps are surfaced as
:class:`UnsupportedStep` so a procedure fails loudly instead of silently
skipping chemistry.

All quantities are stored in LabForge base units (mL, seconds, °C, RPM) after
parsing; the raw XDL strings are kept on ``raw`` for round-tripping / debugging.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from labforge import units


@dataclass
class Step:
    """Base class for all procedure steps."""

    #: Original XDL attribute dict, preserved verbatim.
    raw: dict = field(default_factory=dict, repr=False)

    #: XDL tag name, e.g. "Add". Overridden per subclass.
    xdl_name: str = field(default="Step", init=False)

    def summary(self) -> str:
        """One-line human description used in logs and dry-runs."""
        return self.xdl_name


@dataclass
class Add(Step):
    """Add a reagent to a vessel.

    Maps to: draw ``volume`` of ``reagent`` and dispense it into ``vessel``
    using whichever pump the hardware graph wires between them.
    """

    reagent: str = ""
    vessel: str = ""
    volume_ml: Optional[float] = None
    time_s: Optional[float] = None
    stir: bool = False

    def __post_init__(self):
        self.xdl_name = "Add"

    def summary(self) -> str:
        vol = f"{self.volume_ml:g} mL" if self.volume_ml is not None else "?"
        tail = " (stirring)" if self.stir else ""
        return f"Add {vol} of {self.reagent} to {self.vessel}{tail}"


@dataclass
class Transfer(Step):
    """Move liquid from one vessel to another."""

    from_vessel: str = ""
    to_vessel: str = ""
    volume_ml: Optional[float] = None  # None => "all"
    time_s: Optional[float] = None

    def __post_init__(self):
        self.xdl_name = "Transfer"

    def summary(self) -> str:
        vol = f"{self.volume_ml:g} mL" if self.volume_ml is not None else "all"
        return f"Transfer {vol} from {self.from_vessel} to {self.to_vessel}"


@dataclass
class Stir(Step):
    """Start stirring a vessel (optionally for a fixed time, then stop)."""

    vessel: str = ""
    time_s: Optional[float] = None
    speed_rpm: Optional[float] = None

    def __post_init__(self):
        self.xdl_name = "Stir"

    def summary(self) -> str:
        parts = [f"Stir {self.vessel}"]
        if self.speed_rpm is not None:
            parts.append(f"at {self.speed_rpm:g} RPM")
        if self.time_s is not None:
            parts.append(f"for {self.time_s:g} s")
        return " ".join(parts)


@dataclass
class StopStir(Step):
    """Stop stirring a vessel."""

    vessel: str = ""

    def __post_init__(self):
        self.xdl_name = "StopStir"

    def summary(self) -> str:
        return f"Stop stirring {self.vessel}"


@dataclass
class HeatChill(Step):
    """Bring a vessel to a target temperature and optionally hold it."""

    vessel: str = ""
    temp_c: Optional[float] = None
    time_s: Optional[float] = None
    stir: bool = False

    def __post_init__(self):
        self.xdl_name = "HeatChill"

    def summary(self) -> str:
        parts = [f"HeatChill {self.vessel}"]
        if self.temp_c is not None:
            parts.append(f"to {self.temp_c:g} °C")
        if self.time_s is not None:
            parts.append(f"for {self.time_s:g} s")
        return " ".join(parts)


@dataclass
class Wait(Step):
    """Wait for a fixed duration."""

    time_s: float = 0.0

    def __post_init__(self):
        self.xdl_name = "Wait"

    def summary(self) -> str:
        return f"Wait {self.time_s:g} s"


@dataclass
class CleanVessel(Step):
    """Rinse a vessel with a solvent, sending waste to the waste line."""

    vessel: str = ""
    solvent: str = ""
    volume_ml: Optional[float] = None
    repeats: int = 1

    def __post_init__(self):
        self.xdl_name = "CleanVessel"

    def summary(self) -> str:
        vol = f"{self.volume_ml:g} mL" if self.volume_ml is not None else "?"
        return f"Clean {self.vessel} with {vol} {self.solvent} x{self.repeats}"


@dataclass
class Comment(Step):
    """A no-op annotation carried through to the run log."""

    text: str = ""

    def __post_init__(self):
        self.xdl_name = "Comment"

    def summary(self) -> str:
        return f"# {self.text}"


@dataclass
class UnsupportedStep(Step):
    """A recognised XDL tag that LabForge cannot execute on this hardware class.

    Kept as an object (rather than dropped) so the compiler can refuse to run a
    procedure that contains chemistry it would otherwise silently skip.
    """

    tag: str = ""

    def __post_init__(self):
        self.xdl_name = self.tag or "Unsupported"

    def summary(self) -> str:
        return f"[unsupported] {self.xdl_name}"


# Tags LabForge knows how to build. Mapping is used by the parser.
_BUILDERS = {}


def _register(tag):
    def deco(fn):
        _BUILDERS[tag] = fn
        return fn

    return deco


def _f(attrs, key, parser):
    val = attrs.get(key)
    if val is None or str(val).strip() == "":
        return None
    return parser(val)


def _bool(attrs, key, default=False):
    val = attrs.get(key)
    if val is None:
        return default
    return str(val).strip().lower() in ("true", "1", "yes", "on")


@_register("Add")
def _build_add(attrs):
    return Add(
        raw=dict(attrs),
        reagent=attrs.get("reagent", ""),
        vessel=attrs.get("vessel", ""),
        volume_ml=_f(attrs, "volume", units.parse_volume_ml),
        time_s=_f(attrs, "time", units.parse_time_s),
        stir=_bool(attrs, "stir"),
    )


@_register("Transfer")
def _build_transfer(attrs):
    vol_raw = attrs.get("volume")
    volume = None
    if vol_raw is not None and str(vol_raw).strip().lower() not in ("", "all"):
        volume = units.parse_volume_ml(vol_raw)
    return Transfer(
        raw=dict(attrs),
        from_vessel=attrs.get("from_vessel", attrs.get("from", "")),
        to_vessel=attrs.get("to_vessel", attrs.get("to", "")),
        volume_ml=volume,
        time_s=_f(attrs, "time", units.parse_time_s),
    )


@_register("Stir")
def _build_stir(attrs):
    return Stir(
        raw=dict(attrs),
        vessel=attrs.get("vessel", ""),
        time_s=_f(attrs, "time", units.parse_time_s),
        speed_rpm=_f(attrs, "stir_speed", units.parse_speed_rpm),
    )


@_register("StopStir")
def _build_stop_stir(attrs):
    return StopStir(raw=dict(attrs), vessel=attrs.get("vessel", ""))


@_register("HeatChill")
@_register("HeatChillToTemp")
def _build_heatchill(attrs):
    return HeatChill(
        raw=dict(attrs),
        vessel=attrs.get("vessel", ""),
        temp_c=_f(attrs, "temp", units.parse_temp_c),
        time_s=_f(attrs, "time", units.parse_time_s),
        stir=_bool(attrs, "stir"),
    )


@_register("Wait")
def _build_wait(attrs):
    return Wait(raw=dict(attrs), time_s=_f(attrs, "time", units.parse_time_s) or 0.0)


@_register("CleanVessel")
def _build_clean(attrs):
    repeats = attrs.get("repeats", "1")
    try:
        repeats = max(1, int(float(repeats)))
    except (TypeError, ValueError):
        repeats = 1
    return CleanVessel(
        raw=dict(attrs),
        vessel=attrs.get("vessel", ""),
        solvent=attrs.get("solvent", ""),
        volume_ml=_f(attrs, "volume", units.parse_volume_ml),
        repeats=repeats,
    )


@_register("Comment")
def _build_comment(attrs):
    return Comment(raw=dict(attrs), text=attrs.get("comment", attrs.get("text", "")))


def build_step(tag, attrs):
    """Build a :class:`Step` from an XDL tag name and attribute dict."""
    builder = _BUILDERS.get(tag)
    if builder is None:
        return UnsupportedStep(raw=dict(attrs), tag=tag)
    return builder(attrs)


def supported_tags():
    """Return the set of XDL tags LabForge can execute."""
    return set(_BUILDERS)
