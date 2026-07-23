"""Fuzzy matching between a YouTube Music track and Spotify search results.

The existing converters in the wild mostly do a single exact/substring
comparison and give up, which produces a lot of false negatives for
remixes, "feat." credits, and live/cover versions. This scores every
candidate on title similarity, artist similarity, and duration proximity,
then picks the best one -- while still surfacing anything below a
confidence threshold instead of silently accepting a bad match.
"""

from __future__ import annotations

from dataclasses import dataclass

from rapidfuzz import fuzz

from .models import SourceTrack, SpotifyCandidate
from .text_utils import normalize, strip_noise

# Weights were tuned by hand against a mix of clean and messy YouTube Music
# titles; title similarity dominates but a wildly different artist or
# duration should still be able to sink an otherwise close title match.
TITLE_WEIGHT = 0.55
ARTIST_WEIGHT = 0.35
DURATION_WEIGHT = 0.10

DEFAULT_CONFIDENCE_THRESHOLD = 72.0
DURATION_TOLERANCE_SECONDS = 12


@dataclass
class ScoredCandidate:
    candidate: SpotifyCandidate
    score: float
    title_score: float
    artist_score: float
    duration_score: float


def _duration_score(a: int | None, b: int | None) -> float:
    if a is None or b is None:
        return 60.0  # neutral score when duration is unknown, not a penalty
    diff = abs(a - b)
    if diff <= DURATION_TOLERANCE_SECONDS:
        return 100.0
    if diff >= 60:
        return 0.0
    return max(0.0, 100.0 - (diff - DURATION_TOLERANCE_SECONDS) * (100.0 / 48.0))


def _artist_score(source_artists: list[str], candidate_artists: list[str]) -> float:
    if not source_artists or not candidate_artists:
        return 50.0
    best = 0.0
    for sa in source_artists:
        sa_norm = normalize(sa)
        for ca in candidate_artists:
            ca_norm = normalize(ca)
            best = max(best, fuzz.token_set_ratio(sa_norm, ca_norm))
    return best


def score_candidate(source: SourceTrack, candidate: SpotifyCandidate) -> ScoredCandidate:
    title_score = fuzz.token_sort_ratio(
        normalize(strip_noise(source.title)), normalize(candidate.title)
    )
    artist_score = _artist_score(source.artists, candidate.artists)
    duration_score = _duration_score(source.duration_seconds, candidate.duration_seconds)

    total = (
        title_score * TITLE_WEIGHT
        + artist_score * ARTIST_WEIGHT
        + duration_score * DURATION_WEIGHT
    )
    return ScoredCandidate(
        candidate=candidate,
        score=round(total, 2),
        title_score=title_score,
        artist_score=artist_score,
        duration_score=duration_score,
    )


def rank_candidates(
    source: SourceTrack, candidates: list[SpotifyCandidate]
) -> list[ScoredCandidate]:
    scored = [score_candidate(source, c) for c in candidates]
    scored.sort(key=lambda s: s.score, reverse=True)
    return scored


def best_match(
    source: SourceTrack,
    candidates: list[SpotifyCandidate],
    threshold: float = DEFAULT_CONFIDENCE_THRESHOLD,
) -> tuple[ScoredCandidate | None, list[ScoredCandidate]]:
    """Return the best-scoring candidate (if any) plus the full ranking.

    The best candidate is returned regardless of threshold; callers decide
    whether to auto-accept, flag as low-confidence, or prompt the user by
    comparing its score against `threshold`.
    """
    ranked = rank_candidates(source, candidates)
    if not ranked:
        return None, []
    return ranked[0], ranked
