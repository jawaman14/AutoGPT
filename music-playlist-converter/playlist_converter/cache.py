"""Persistent cache for Spotify search results.

Search-heavy conversions are the slowest and most rate-limit-prone part of
the whole process. Caching normalized-query -> raw search results on disk
(SQLite) means re-runs, `--resume`, and repeat conversions of overlapping
playlists don't re-hit the Spotify API for tracks already looked up.
"""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path


class SearchCache:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(path))
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS search_cache (
                query_key TEXT PRIMARY KEY,
                results_json TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """
        )
        self._conn.commit()

    def get(self, query_key: str) -> list[dict] | None:
        row = self._conn.execute(
            "SELECT results_json FROM search_cache WHERE query_key = ?",
            (query_key,),
        ).fetchone()
        if row is None:
            return None
        return json.loads(row[0])

    def set(self, query_key: str, results: list[dict]) -> None:
        self._conn.execute(
            "INSERT OR REPLACE INTO search_cache (query_key, results_json, created_at) "
            "VALUES (?, ?, ?)",
            (query_key, json.dumps(results), time.time()),
        )
        self._conn.commit()

    def clear(self) -> None:
        self._conn.execute("DELETE FROM search_cache")
        self._conn.commit()

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> "SearchCache":
        return self

    def __exit__(self, *exc_info) -> None:
        self.close()
