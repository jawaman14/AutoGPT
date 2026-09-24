"""Entry point: `python -m skyrunner`."""
from __future__ import annotations

import argparse
from pathlib import Path

from .game import Session

SAVE = Path.home() / ".skyrunner" / "save.json"


def main() -> None:
    ap = argparse.ArgumentParser(description="Skyrunner - bush-flying cargo game on JSBSim")
    ap.add_argument("--new", action="store_true", help="ignore the save file and start fresh")
    ap.add_argument("--seed", type=int, default=1, help="job board RNG seed")
    args = ap.parse_args()

    if args.new and SAVE.exists():
        SAVE.unlink()
    session = Session.load_or_new(SAVE, seed=args.seed)

    from .render.app import run  # imported late so headless use never needs a display

    run(session)


if __name__ == "__main__":
    main()
