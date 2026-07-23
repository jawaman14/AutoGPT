"""Orchestrates matching source tracks against Spotify and building the playlist."""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Callable, Iterable

from .matching import DEFAULT_CONFIDENCE_THRESHOLD, ScoredCandidate, best_match
from .models import MatchResult, MatchStatus, SourceTrack
from .spotify_target import SpotifyTarget
from .state import RunState, load_state, save_state, state_file_path

logger = logging.getLogger("playlist_converter")

# Callback invoked for a low-confidence match: given the source track and the
# ranked candidates, return the chosen ScoredCandidate, or None to skip it.
InteractiveResolver = Callable[[SourceTrack, list[ScoredCandidate]], ScoredCandidate | None]

# Callback invoked after each track is processed, for progress reporting.
ProgressCallback = Callable[[int, int, MatchResult], None]


class ConversionRun:
    def __init__(
        self,
        target: SpotifyTarget,
        state_dir: Path,
        threshold: float = DEFAULT_CONFIDENCE_THRESHOLD,
        candidates_per_search: int = 8,
    ):
        self.target = target
        self.state_dir = state_dir
        self.threshold = threshold
        self.candidates_per_search = candidates_per_search

    def match_tracks(
        self,
        source_tracks: list[SourceTrack],
        run_state: RunState,
        interactive_resolver: InteractiveResolver | None = None,
        progress_cb: ProgressCallback | None = None,
    ) -> list[MatchResult]:
        results: list[MatchResult] = []
        total = len(source_tracks)

        for i, source in enumerate(source_tracks, start=1):
            cached_state = run_state.tracks.get(source.video_id)
            if cached_state and cached_state.status == MatchStatus.MATCHED.value:
                result = MatchResult(
                    source=source,
                    status=MatchStatus.MATCHED,
                    score=cached_state.score,
                )
                results.append(result)
                if progress_cb:
                    progress_cb(i, total, result)
                continue

            candidates = self.target.search(source, limit=self.candidates_per_search)
            top, ranked = best_match(source, candidates, threshold=self.threshold)

            if top is None:
                result = MatchResult(source=source, status=MatchStatus.NOT_FOUND)
            elif top.score >= self.threshold:
                result = MatchResult(
                    source=source,
                    status=MatchStatus.MATCHED,
                    candidate=top.candidate,
                    score=top.score,
                    alternatives=[c.candidate for c in ranked[1:5]],
                )
            elif interactive_resolver is not None:
                chosen = interactive_resolver(source, ranked)
                if chosen is not None:
                    result = MatchResult(
                        source=source,
                        status=MatchStatus.MATCHED,
                        candidate=chosen.candidate,
                        score=chosen.score,
                    )
                else:
                    result = MatchResult(
                        source=source,
                        status=MatchStatus.USER_REJECTED,
                        candidate=top.candidate,
                        score=top.score,
                        alternatives=[c.candidate for c in ranked[1:5]],
                    )
            else:
                result = MatchResult(
                    source=source,
                    status=MatchStatus.LOW_CONFIDENCE,
                    candidate=top.candidate,
                    score=top.score,
                    alternatives=[c.candidate for c in ranked[1:5]],
                )

            run_state.mark(
                source.video_id,
                result.status,
                result.candidate.uri if result.candidate else None,
                result.score,
            )
            results.append(result)
            if progress_cb:
                progress_cb(i, total, result)

        return results

    def apply_to_spotify(
        self,
        results: list[MatchResult],
        playlist_name: str,
        description: str,
        public: bool,
        run_state: RunState,
        state_path: Path,
        skip_duplicates: bool = True,
        dry_run: bool = False,
    ) -> tuple[str | None, int]:
        """Create/reuse the destination playlist and add matched tracks.

        Returns (spotify_playlist_id, number_of_tracks_added). In dry-run
        mode no Spotify writes happen and the playlist id is None.
        """
        uris_to_add: list[str] = []
        matched = [r for r in results if r.status == MatchStatus.MATCHED and r.candidate]

        if dry_run:
            return None, len(matched)

        if run_state.spotify_playlist_id:
            playlist_id = run_state.spotify_playlist_id
        else:
            existing = self.target.find_playlist_by_name(playlist_name)
            if existing:
                playlist_id = existing["id"]
                logger.info("Reusing existing Spotify playlist '%s'", playlist_name)
            else:
                created = self.target.create_playlist(playlist_name, description, public)
                playlist_id = created["id"]
            run_state.spotify_playlist_id = playlist_id
            save_state(state_path, run_state)

        existing_uris: set[str] = set()
        if skip_duplicates:
            existing_uris = self.target.get_playlist_track_uris(playlist_id)

        for result in matched:
            uri = result.candidate.uri
            if skip_duplicates and uri in existing_uris:
                result.status = MatchStatus.SKIPPED_DUPLICATE
                run_state.mark(result.source.video_id, result.status, uri, result.score)
                continue
            uris_to_add.append(uri)
            existing_uris.add(uri)

        if uris_to_add:
            self.target.add_tracks(playlist_id, uris_to_add)
            for result in matched:
                if result.candidate.uri in uris_to_add:
                    run_state.mark(
                        result.source.video_id,
                        MatchStatus.MATCHED,
                        result.candidate.uri,
                        result.score,
                    )
            save_state(state_path, run_state)

        return playlist_id, len(uris_to_add)


def get_state(state_dir: Path, playlist_id: str, playlist_name: str) -> tuple[RunState, Path]:
    path = state_file_path(state_dir, playlist_id, playlist_name)
    return load_state(path, playlist_id), path
