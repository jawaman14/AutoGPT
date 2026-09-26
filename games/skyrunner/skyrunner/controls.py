"""Turns digital key presses (and optional analog axes) into smooth control
surface commands. Keyboard flying is only tolerable with rate limiting and
auto-centring; the mouse-yoke mode gives proportional control."""
from __future__ import annotations

from dataclasses import dataclass, field

from .fdm import Controls

FLAP_NOTCHES = (0.0, 0.33, 0.66, 1.0)


def _approach(cur: float, target: float, rate: float, dt: float) -> float:
    step = rate * dt
    if abs(target - cur) <= step:
        return target
    return cur + step if target > cur else cur - step


@dataclass
class InputFrame:
    """Everything the renderer collected this frame."""
    held: set[str] = field(default_factory=set)  # logical actions currently held
    pressed: set[str] = field(default_factory=set)  # one-shot actions this frame
    stick: tuple[float, float] | None = None  # analog (roll, pitch) -1..1, pitch +1 = pull
    rudder_axis: float | None = None
    throttle_axis: float | None = None


@dataclass
class ControlMapper:
    controls: Controls = field(default_factory=Controls)
    flap_index: int = 0
    roll_authority: float = 0.65
    pitch_authority: float = 0.6

    def reset(self, throttle: float = 0.0) -> None:
        self.controls = Controls(throttle=throttle)
        self.flap_index = 0

    def update(self, dt: float, inp: InputFrame) -> Controls:
        c = self.controls
        h = inp.held
        # roll / pitch
        if inp.stick is not None:
            roll_t, pitch_t = inp.stick
            c.aileron = roll_t
            c.elevator = -pitch_t
        else:
            roll_t = (("roll_right" in h) - ("roll_left" in h)) * self.roll_authority
            pitch_t = (("pitch_down" in h) - ("pitch_up" in h)) * self.pitch_authority
            c.aileron = _approach(c.aileron, roll_t, 2.5 if roll_t else 4.0, dt)
            c.elevator = _approach(c.elevator, pitch_t, 2.0 if pitch_t else 3.0, dt)
        # rudder
        if inp.rudder_axis is not None:
            c.rudder = inp.rudder_axis
        else:
            rud_t = ("yaw_right" in h) - ("yaw_left" in h)
            c.rudder = _approach(c.rudder, float(rud_t), 3.0 if rud_t else 4.0, dt)
        # throttle
        if inp.throttle_axis is not None:
            c.throttle = inp.throttle_axis
        else:
            c.throttle += (("throttle_up" in h) - ("throttle_down" in h)) * 0.6 * dt
        if "throttle_cut" in inp.pressed:
            c.throttle = 0.0
        if "throttle_full" in inp.pressed:
            c.throttle = 1.0
        c.throttle = min(1.0, max(0.0, c.throttle))
        # trim
        c.pitch_trim += (("trim_up" in h) - ("trim_down" in h)) * -0.35 * dt
        c.pitch_trim = min(1.0, max(-1.0, c.pitch_trim))
        # flaps
        if "flaps_down" in inp.pressed:
            self.flap_index = min(len(FLAP_NOTCHES) - 1, self.flap_index + 1)
        if "flaps_up" in inp.pressed:
            self.flap_index = max(0, self.flap_index - 1)
        c.flaps = FLAP_NOTCHES[self.flap_index]
        c.brake = 1.0 if "brake" in h else 0.0
        return c
