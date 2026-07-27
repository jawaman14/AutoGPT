"""Resumable run state.

A conversion run can be interrupted (rate limits, network blips, the user
hitting Ctrl-C). Progress is checkpointed to a JSON file per source
playlist so `--resume` can pick up exactly where it left off instead of
re-searching and re-adding tracks that already succeeded.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .models import MatchStatus, SpotifyCandidate

# Statuses that represent a settled decision: safe to skip re-matching (and,
# for MATCHED/SKIPPED_DUPLICATE, re-adding is idempotent via the duplicate
# check anyway) on --resume without re-searching or re-prompting the user.
RESUMABLE_TERMINAL_STATUSES = (
    MatchStatus.MATCHED.value,
    MatchStatus.SKIPPED_DUPLICATE.value,
    MatchStatus.USER_REJECTED.value,
)


@dataclass
class TrackState:
    video_id: str
    status: str
    spotify_uri: str | None = None
    score: float = 0.0
    candidate_title: str | None = None
    candidate_artists: list[str] = field(default_factory=list)

    def to_candidate(self) -> SpotifyCandidate | None:
        if not self.spotify_uri:
            return None
        return SpotifyCandidate(
            uri=self.spotify_uri,
            title=self.candidate_title or "",
            artists=self.candidate_artists,
            album=None,
            duration_seconds=None,
        )


@dataclass
class RunState:
    playlist_id: str
    spotify_playlist_id: str | None = None
    tracks: dict[str, TrackState] = field(default_factory=dict)

    def mark(
        self,
        video_id: str,
        status: MatchStatus,
        candidate: SpotifyCandidate | None,
        score: float,
    ) -> None:
        self.tracks[video_id] = TrackState(
            video_id=video_id,
            status=status.value,
            spotify_uri=candidate.uri if candidate else None,
            score=score,
            candidate_title=candidate.title if candidate else None,
            candidate_artists=candidate.artists if candidate else [],
        )

    def is_done(self, video_id: str) -> bool:
        state = self.tracks.get(video_id)
        return state is not None and state.status in RESUMABLE_TERMINAL_STATUSES


def state_file_path(state_dir: Path, playlist_id: str, spotify_playlist_name: str) -> Path:
    digest = hashlib.sha256(f"{playlist_id}:{spotify_playlist_name}".encode()).hexdigest()[:16]
    return state_dir / f"run_{digest}.json"


def load_state(path: Path, playlist_id: str) -> RunState:
    if not path.exists():
        return RunState(playlist_id=playlist_id)
    raw = json.loads(path.read_text())
    tracks = {k: TrackState(**v) for k, v in raw.get("tracks", {}).items()}
    return RunState(
        playlist_id=raw.get("playlist_id", playlist_id),
        spotify_playlist_id=raw.get("spotify_playlist_id"),
        tracks=tracks,
    )


def save_state(path: Path, state: RunState) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "playlist_id": state.playlist_id,
        "spotify_playlist_id": state.spotify_playlist_id,
        "tracks": {k: asdict(v) for k, v in state.tracks.items()},
    }
    path.write_text(json.dumps(payload, indent=2))
