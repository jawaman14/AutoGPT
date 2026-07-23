"""Builds a human-readable + machine-readable report of a conversion run."""

from __future__ import annotations

import csv
import json
from pathlib import Path

from .models import MatchResult, MatchStatus

STATUS_ORDER = [
    MatchStatus.MATCHED,
    MatchStatus.SKIPPED_DUPLICATE,
    MatchStatus.LOW_CONFIDENCE,
    MatchStatus.USER_REJECTED,
    MatchStatus.NOT_FOUND,
]


def summarize(results: list[MatchResult]) -> dict[str, int]:
    counts = {status.value: 0 for status in STATUS_ORDER}
    for result in results:
        counts[result.status.value] += 1
    return counts


def match_rate(results: list[MatchResult]) -> float:
    """Percentage of tracks that ended up matched (including de-duped ones)."""
    if not results:
        return 0.0
    matched = sum(
        1 for r in results if r.status in (MatchStatus.MATCHED, MatchStatus.SKIPPED_DUPLICATE)
    )
    return round(100 * matched / len(results), 1)


def needs_review(results: list[MatchResult]) -> list[MatchResult]:
    return [
        r
        for r in results
        if r.status in (MatchStatus.LOW_CONFIDENCE, MatchStatus.NOT_FOUND, MatchStatus.USER_REJECTED)
    ]


def write_csv_report(results: list[MatchResult], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "status",
                "score",
                "youtube_title",
                "youtube_artists",
                "youtube_video_id",
                "spotify_match",
                "spotify_artists",
                "spotify_uri",
            ]
        )
        for r in results:
            writer.writerow(
                [
                    r.status.value,
                    r.score,
                    r.source.title,
                    r.source.artist_display,
                    r.source.video_id,
                    r.candidate.title if r.candidate else "",
                    r.candidate.artist_display if r.candidate else "",
                    r.candidate.uri if r.candidate else "",
                ]
            )


def write_json_report(results: list[MatchResult], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = [
        {
            "status": r.status.value,
            "score": r.score,
            "youtube": {
                "title": r.source.title,
                "artists": r.source.artists,
                "video_id": r.source.video_id,
            },
            "spotify_match": (
                {
                    "title": r.candidate.title,
                    "artists": r.candidate.artists,
                    "uri": r.candidate.uri,
                }
                if r.candidate
                else None
            ),
            "alternatives": [
                {"title": c.title, "artists": c.artists, "uri": c.uri}
                for c in r.alternatives
            ],
        }
        for r in results
    ]
    path.write_text(json.dumps(payload, indent=2))
