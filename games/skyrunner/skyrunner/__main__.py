"""Entry point.

  python -m skyrunner                      # sandbox, solo
  python -m skyrunner --mode campaign      # story mode (1979 ->)
  python -m skyrunner --mode coop          # host: friends join as co-pilot / spotter
  python -m skyrunner --mode versus        # host: a friend runs the task-force desk
  python -m skyrunner --police             # play the task force against AI runners
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
    args = ap.parse_args()

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
    session = Session.load_or_new(save, seed=args.seed, mode=mode)
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

    run(session, server=server)


if __name__ == "__main__":
    main()
