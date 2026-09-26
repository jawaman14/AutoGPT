"""Entry point.

  python -m skyrunner                      # sandbox, solo
  python -m skyrunner --mode campaign      # story mode (1979 ->)
  python -m skyrunner --mode coop          # host: friends join as co-pilot / spotter
  python -m skyrunner --mode versus        # host: a friend runs the task-force desk
  python -m skyrunner --police             # play the task force against AI runners
  python -m skyrunner --players 6          # seats and rule layers for a table of six
  python -m skyrunner --watch --graphics low   # the AI flies the career; you watch
"""
from __future__ import annotations

import argparse
from pathlib import Path

from .game import Session
from .roles import Mode

SAVE_DIR = Path.home() / ".skyrunner"


def main() -> None:
    ap = argparse.ArgumentParser(description="Skyrunner - bush flying, cargo and the long arm of the law")
    ap.add_argument("--mode", choices=["solo", "campaign", "coop", "versus"], default="solo")
    ap.add_argument("--police", action="store_true", help="play the task-force desk against AI runners")
    ap.add_argument("--host", action="store_true", help="accept remote seats (implied by coop/versus)")
    ap.add_argument("--port", type=int, default=47800)
    ap.add_argument("--bind", default="0.0.0.0", help="address to listen on when hosting")
    ap.add_argument("--new", action="store_true", help="ignore the save file and start fresh")
    ap.add_argument("--seed", type=int, default=1, help="job board RNG seed")
    ap.add_argument("--players", type=int, help="how many people are playing: picks mode, seats and rule layer")
    ap.add_argument("--layer", type=int, choices=[1, 2, 3, 4, 5], help="rule layer (5 = HQs and seasons)")
    ap.add_argument("--graphics", choices=["low", "medium", "high"], default="high")
    ap.add_argument("--watch", action="store_true", help="the pilot bot flies; you watch (and can host seats)")
    args = ap.parse_args()
    features = None
    if args.players or args.layer:
        from .layers import features_for, plan_match

        plan = plan_match(args.players or 1, versus=args.mode != "coop", layer=args.layer)
        print(plan.describe())
        args.mode = plan.mode.value if args.mode in ("solo", "coop", "versus") else args.mode
        features = features_for(plan.layer) | ({"hq"} if plan.layer >= 5 else set())

    if args.police:
        from .station import main as station_main
        import sys

        sys.argv = [sys.argv[0], "--police", "--seed", str(args.seed)]
        station_main()
        return

    mode = Mode(args.mode)
    save = SAVE_DIR / ("campaign.json" if mode == Mode.CAMPAIGN else "save.json")
    if args.new and save.exists():
        save.unlink()
    session = Session.load_or_new(save, seed=args.seed, mode=mode, features=features)
    if mode == Mode.CAMPAIGN:
        from .campaign import Campaign

        Campaign.from_dict(Session.read_save(save).get("campaign")).attach(session)

    server = None
    if args.host or mode in (Mode.COOP, Mode.VERSUS):
        from .net.server import HostServer

        server = HostServer(args.bind, args.port, mode if mode != Mode.SOLO else Mode.COOP).start()
        roles = "copilot, spotter" + (", controller" if mode == Mode.VERSUS else "")
        session.say(f"Hosting on port {server.port}: friends run "
                    f"`python -m skyrunner.station --connect YOUR_IP:{server.port} --role <{roles}>`")
        print(f"Hosting {mode.value} on {args.bind}:{server.port} (seats: {roles})")

    from .render.app import run  # imported late so headless use never needs a display

    bot = None
    if args.watch:
        from .bots.autorun import AutoRunner

        bot = AutoRunner(session)
        session.say("Watching the AI fly. [C] cycles cameras.")
    run(session, server=server, graphics=args.graphics, bot=bot)


if __name__ == "__main__":
    main()
