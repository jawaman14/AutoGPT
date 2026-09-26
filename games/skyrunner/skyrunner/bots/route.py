"""Terrain-masking route planner: follow the valleys, stay under the radar.

Dijkstra over a coarse copy of the height map (250 m cells). Moving into
higher ground costs extra and so does simply being high, so the cheapest
path threads through low ground: the classic low-level smuggling route,
and one that a loaded single can actually climb.
"""
from __future__ import annotations

import heapq
import math

import numpy as np

from ..world import HALF

CELL_M = 250.0
_cache: dict[int, np.ndarray] = {}


def _grid(world) -> np.ndarray:
    key = id(world)
    if key not in _cache:
        n = int(2 * HALF / CELL_M) + 1
        xs = np.linspace(-HALF, HALF, n)
        X, Y = np.meshgrid(xs, xs)
        h = np.maximum(world.heights_many(X.ravel(), Y.ravel()).reshape(n, n), 0.0)
        # a cell is as high as its highest neighbour: don't thread needles
        pad = np.pad(h, 1, mode="edge")
        h = np.max([pad[1 + dj:1 + dj + n, 1 + di:1 + di + n] for dj in (-1, 0, 1) for di in (-1, 0, 1)], axis=0)
        _cache[key] = h
    return _cache[key]


def _cell(x: float, y: float, n: int) -> tuple[int, int]:
    return (int(round((y + HALF) / CELL_M)) if 0 <= (y + HALF) / CELL_M < n else max(0, min(n - 1, int((y + HALF) / CELL_M))),
            max(0, min(n - 1, int(round((x + HALF) / CELL_M)))))


def plan_route(world, start: tuple[float, float], goal: tuple[float, float], climb_weight: float = 6.0,
               height_weight: float = 1.5, spacing_m: float = 1500.0) -> list[tuple[float, float]]:
    """Waypoints (excluding start, including goal)."""
    h = _grid(world)
    n = h.shape[0]
    sj, si = _cell(*start, n)
    gj, gi = _cell(*goal, n)
    dist = np.full((n, n), np.inf)
    prev = -np.ones((n, n, 2), dtype=int)
    dist[sj, si] = 0.0
    pq = [(0.0, sj, si)]
    steps = [(dj, di, math.hypot(dj, di) * CELL_M) for dj in (-1, 0, 1) for di in (-1, 0, 1) if dj or di]
    hmin = float(h.min())
    while pq:
        d, j, i = heapq.heappop(pq)
        if d > dist[j, i]:
            continue
        if (j, i) == (gj, gi):
            break
        hc = h[j, i]
        for dj, di, step in steps:
            jj, ii = j + dj, i + di
            if not (0 <= jj < n and 0 <= ii < n):
                continue
            hn = h[jj, ii]
            cost = step * (1.0 + climb_weight * max(0.0, hn - hc) / step + height_weight * (hn - hmin) / 1000.0)
            nd = d + cost
            if nd < dist[jj, ii]:
                dist[jj, ii] = nd
                prev[jj, ii] = (j, i)
                heapq.heappush(pq, (nd, jj, ii))
    path = []
    j, i = gj, gi
    while (j, i) != (sj, si) and prev[j, i][0] >= 0:
        path.append((i * CELL_M - HALF, j * CELL_M - HALF))
        j, i = prev[j, i]
    path.reverse()
    # thin to one waypoint every `spacing_m`, always keep the goal exact
    out, acc, last = [], 0.0, start
    for p in path:
        acc += math.dist(p, last)
        last = p
        if acc >= spacing_m:
            out.append(p)
            acc = 0.0
    out.append(goal)
    return out
