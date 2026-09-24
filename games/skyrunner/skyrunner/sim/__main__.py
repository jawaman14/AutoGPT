"""Balance tooling CLI.

  python -m skyrunner.sim feasibility            # aircraft x strip x load, flown by the bot (~3 min)
  python -m skyrunner.sim tactical --seeds 3     # bot runs vs the AI task force (~10 min)
  python -m skyrunner.sim strategic --n 200      # HQ seasons, policy vs policy (~10 s)
  python -m skyrunner.sim report                 # rebuild docs/BALANCE.md from saved results
  python -m skyrunner.sim all

Results are saved as JSON under sim-results/ so the report can be rebuilt
without re-flying anything.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

RESULTS = Path("sim-results")


def _save(name: str, data) -> None:
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / f"{name}.json").write_text(json.dumps(data))


def _load(name: str):
    p = RESULTS / f"{name}.json"
    return json.loads(p.read_text()) if p.exists() else None


def cmd_feasibility(args) -> None:
    from .feasibility import sweep, table

    t = time.time()
    r = sweep(workers=args.workers)
    _save("feasibility", r)
    print(table(r))
    print(f"{len(r)} trials in {time.time() - t:.0f} s")


def cmd_tactical(args) -> None:
    from .tactical import calibrate, sweep

    t = time.time()
    r = sweep(seeds=args.seeds, workers=args.workers)
    _save("tactical", r)
    cal = calibrate(r)
    _save("calibration", cal.__dict__)
    print(f"{len(r)} flights in {time.time() - t:.0f} s; calibration: {cal}")


def cmd_strategic(args) -> None:
    from ..hq import Calibration
    from .strategic import equilibrium, matrix, run_matrix, summary

    cal = None
    c = _load("calibration") if args.calibrated else None
    if c:
        cal = Calibration(**c)
    t = time.time()
    r = run_matrix(n=args.n, cal=cal, workers=args.workers)
    for x in r:
        x.pop("history", None)
    _save("strategic", r)
    R, L, m = matrix(r)
    p, q, v = equilibrium(m)
    print(f"{len(r)} seasons in {time.time() - t:.1f} s; equilibrium runner win {v:.3f}")
    print(summary(r))
    abl = {}
    for mech in ("bribe", "wiretap", "decoys", "crews", "audit", "recruit", "lawyer", "opsec", "comeback"):
        rr = run_matrix(n=max(20, args.n // 4), cal=cal, disable=(mech,), workers=args.workers)
        _, _, mm = matrix(rr)
        abl[mech] = equilibrium(mm)[2]
    _save("ablation", {"base": v, "without": abl})
    print("ablations (equilibrium runner win without each mechanic):", {k: round(x, 3) for k, x in abl.items()})


def cmd_report(args) -> None:
    from .report import write_report

    path = write_report(RESULTS, Path(args.out))
    print(f"wrote {path}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Skyrunner balance simulations")
    ap.add_argument("what", choices=["feasibility", "tactical", "strategic", "report", "all"])
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--n", type=int, default=200, help="seasons per policy pairing")
    ap.add_argument("--calibrated", action="store_true", default=True)
    ap.add_argument("--out", default="docs/BALANCE.md")
    args = ap.parse_args()
    steps = ["feasibility", "tactical", "strategic", "report"] if args.what == "all" else [args.what]
    for s in steps:
        globals()[f"cmd_{s}"](args)


if __name__ == "__main__":
    main()
