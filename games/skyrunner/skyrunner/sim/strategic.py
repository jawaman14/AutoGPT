"""Season-level balance simulation.

Plays whole seasons of the HQ game between bot policies, thousands of times,
with night outcomes rolled by `hq.resolve_abstract` (rates calibrated from
real bot flights by `sim.tactical`). Measures:

  * win-rate matrix, runner policy x law policy
  * the equilibrium mix (fictitious play on the zero-sum matrix): which
    strategies a smart player would actually use, and the fair win rate
  * dominance: a strategy that beats or ties everything is a design bug
  * how games end (reasons), how long they last, how often the side leading
    at half-time loses (comebacks), and how often it's decided early
  * what each action is worth (win rate when a random bot used it vs not)
  * ablations: switch a mechanic off and see whether anyone notices
"""
from __future__ import annotations

import random
import statistics
from concurrent.futures import ProcessPoolExecutor

import numpy as np

from ..bots.hq import LAW_POLICIES, RUNNER_POLICIES
from ..hq import Calibration, Season, resolve_abstract


def play_season(runner: str, law: str, seed: int, rules: dict | None = None, cal: Calibration | None = None,
                disable: tuple[str, ...] = ()) -> dict:
    rng = random.Random(seed)
    ss = Season(random.Random(seed * 7 + 1), rules)
    for name in disable:  # ablation: that order is simply unavailable
        _disable(ss, name)
    rmem, lmem = {}, {}
    halftime = None
    while ss.phase != "over":
        RUNNER_POLICIES[runner](ss, rng, rmem)
        LAW_POLICIES[law](ss, rng, lmem)
        plan = ss.start_operation()
        ss.finish_night(resolve_abstract(ss, plan, rng, cal))
        if ss.night == int(ss.rules["nights"]) // 2:
            halftime = ss.runner_progress - ss.law_progress
        ss.next_night()
    return {
        "runner": runner, "law": law, "seed": seed, "winner": ss.winner, "reason": ss.reason,
        "nights": ss.night, "halftime": halftime,
        "margin": ss.runner_progress - ss.law_progress,
        "runner_used": rmem.get("used", []), "law_used": lmem.get("used", []),
        "history": ss.history,
    }


def _disable(ss: Season, name: str) -> None:
    for side in ("_r_", "_l_"):
        if hasattr(ss, side + name):
            setattr(ss, side + name, lambda *a, **k: "disabled")
    if name == "comeback":
        ss.rules["comeback_gap"] = 99.0


def _job(args):
    return play_season(*args)


def run_matrix(n: int = 200, rules: dict | None = None, cal: Calibration | None = None, disable=(),
               runners=None, laws=None, workers: int = 4) -> list[dict]:
    runners = runners or list(RUNNER_POLICIES)
    laws = laws or list(LAW_POLICIES)
    jobs = [(r, l, 1000 * i + 17, rules, cal, tuple(disable)) for r in runners for l in laws for i in range(n)]
    if workers <= 1:
        return [_job(j) for j in jobs]
    with ProcessPoolExecutor(workers) as ex:
        return list(ex.map(_job, jobs, chunksize=64))


def matrix(results: list[dict]) -> tuple[list[str], list[str], np.ndarray]:
    runners = sorted({r["runner"] for r in results}, key=list(RUNNER_POLICIES).index)
    laws = sorted({r["law"] for r in results}, key=list(LAW_POLICIES).index)
    m = np.zeros((len(runners), len(laws)))
    cnt = np.zeros_like(m)
    for r in results:
        i, j = runners.index(r["runner"]), laws.index(r["law"])
        m[i, j] += r["winner"] == "runner"
        cnt[i, j] += 1
    return runners, laws, m / np.maximum(cnt, 1)


def equilibrium(m: np.ndarray, iters: int = 20000) -> tuple[np.ndarray, np.ndarray, float]:
    """Fictitious play on the zero-sum game (runner maximises win rate)."""
    nr, nl = m.shape
    rc, lc = np.zeros(nr), np.zeros(nl)
    rc[0] = lc[0] = 1
    for _ in range(iters):
        rc[np.argmax(m @ (lc / lc.sum()))] += 1
        lc[np.argmin((rc / rc.sum()) @ m)] += 1
    p, q = rc / rc.sum(), lc / lc.sum()
    return p, q, float(p @ m @ q)


def dominance(m: np.ndarray, names_r, names_l) -> list[str]:
    notes = []
    for i, a in enumerate(names_r):
        for k, b in enumerate(names_r):
            if i != k and np.all(m[i] >= m[k] - 0.02) and np.any(m[i] > m[k] + 0.05):
                notes.append(f"runner '{a}' dominates '{b}'")
    for j, a in enumerate(names_l):
        for k, b in enumerate(names_l):
            if j != k and np.all(m[:, j] <= m[:, k] + 0.02) and np.any(m[:, j] < m[:, k] - 0.05):
                notes.append(f"law '{a}' dominates '{b}'")
    return notes


def summary(results: list[dict]) -> dict:
    n = len(results)
    reasons: dict[str, int] = {}
    for r in results:
        key = r["reason"].split(":")[0] if r["reason"].startswith("season over") else r["reason"]
        key = r["reason"] if key == "season over" else key
        reasons[f"{r['winner']}: {key}"] = reasons.get(f"{r['winner']}: {key}", 0) + 1
    with_half = [r for r in results if r["halftime"] is not None]
    comebacks = [r for r in with_half if (r["halftime"] > 0) != (r["winner"] == "runner") and abs(r["halftime"]) > 0.02]
    close = [r for r in results if abs(r["margin"]) < 0.25]
    return {
        "seasons": n,
        "runner_win": sum(r["winner"] == "runner" for r in results) / max(1, n),
        "reasons": {k: v / n for k, v in sorted(reasons.items(), key=lambda kv: -kv[1])},
        "nights_mean": statistics.mean(r["nights"] for r in results),
        "ended_early": sum(r["nights"] < int(max(x["nights"] for x in results)) for r in results) / max(1, n),
        "comeback_rate": len(comebacks) / max(1, len(with_half)),
        "close_finish": len(close) / max(1, n),
    }


def action_values(results: list[dict], side: str) -> dict[str, tuple[float, int]]:
    """Win rate of the random bot's side when it used an action at least once vs never."""
    key = "runner_used" if side == "runner" else "law_used"
    pool = [r for r in results if r[side] == "random"]
    acts = sorted({a for r in pool for a in r[key]})
    out = {}
    for a in acts:
        used = [r for r in pool if a in r[key]]
        not_used = [r for r in pool if a not in r[key]]
        if len(used) < 10 or len(not_used) < 10:
            continue
        win = lambda rs: sum(r["winner"] == side for r in rs) / len(rs)  # noqa: E731
        out[a] = (win(used) - win(not_used), len(used))
    return out
