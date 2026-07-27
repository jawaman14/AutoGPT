"""Shared data structures used across the converter."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


@dataclass(frozen=True)
class SourceTrack:
    """A track pulled from a YouTube Music playlist."""

    video_id: str
    title: str
    artists: list[str]
    album: str | None = None
    duration_seconds: int | None = None

    @property
    def artist_display(self) -> str:
        return ", ".join(self.artists) if self.artists else "Unknown Artist"

    @property
    def display(self) -> str:
        return f"{self.artist_display} - {self.title}"


@dataclass(frozen=True)
class SpotifyCandidate:
    """A candidate track returned by a Spotify search."""

    uri: str
    title: str
    artists: list[str]
    album: str | None
    duration_seconds: int | None

    @property
    def artist_display(self) -> str:
        return ", ".join(self.artists) if self.artists else "Unknown Artist"


class MatchStatus(str, Enum):
    MATCHED = "matched"
    LOW_CONFIDENCE = "low_confidence"
    NOT_FOUND = "not_found"
    SKIPPED_DUPLICATE = "skipped_duplicate"
    USER_REJECTED = "user_rejected"


@dataclass
class MatchResult:
    source: SourceTrack
    status: MatchStatus
    candidate: SpotifyCandidate | None = None
    score: float = 0.0
    alternatives: list[SpotifyCandidate] = field(default_factory=list)
