"""End-to-end tests for the matching/apply orchestration using a fake Spotify target.

These specifically guard against a regression where a track resumed from a
previous run's saved state (status MATCHED) would carry `candidate=None`,
causing `apply_to_spotify` to silently skip re-adding it if the destination
playlist add never actually happened (e.g. the run crashed between matching
and applying).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from playlist_converter.converter import ConversionRun
from playlist_converter.models import MatchStatus, SourceTrack, SpotifyCandidate
from playlist_converter.state import RunState, load_state


class FakeSpotifyTarget:
    """Stands in for SpotifyTarget without touching the network."""

    def __init__(self, catalog: dict[str, list[SpotifyCandidate]]):
        self.catalog = catalog
        self.search_calls: list[str] = []
        self.created_playlists: dict[str, str] = {}
        self.playlists: dict[str, list[str]] = {}
        self._next_id = 1

    def search(self, source: SourceTrack, limit: int = 8) -> list[SpotifyCandidate]:
        self.search_calls.append(source.video_id)
        return self.catalog.get(source.video_id, [])

    def find_playlist_by_name(self, name: str):
        pid = self.created_playlists.get(name)
        if pid is None:
            return None
        return {"id": pid, "name": name}

    def create_playlist(self, name: str, description: str, public: bool):
        pid = f"playlist_{self._next_id}"
        self._next_id += 1
        self.created_playlists[name] = pid
        self.playlists[pid] = []
        return {"id": pid}

    def get_playlist_track_uris(self, playlist_id: str) -> set[str]:
        return set(self.playlists.get(playlist_id, []))

    def add_tracks(self, playlist_id: str, uris: list[str]) -> None:
        self.playlists.setdefault(playlist_id, []).extend(uris)


def make_source(video_id, title, artists, duration=200):
    return SourceTrack(video_id=video_id, title=title, artists=artists, duration_seconds=duration)


def make_candidate(uri, title, artists, duration=200):
    return SpotifyCandidate(uri=uri, title=title, artists=artists, album=None, duration_seconds=duration)


@pytest.fixture
def sources():
    return [
        make_source("v1", "Yellow", ["Coldplay"]),
        make_source("v2", "Blinding Lights (Official Video)", ["The Weeknd"]),
        make_source("v3", "Totally Obscure Track", ["Nobody"]),
    ]


@pytest.fixture
def catalog():
    return {
        "v1": [make_candidate("spotify:track:yellow", "Yellow", ["Coldplay"])],
        "v2": [make_candidate("spotify:track:bl", "Blinding Lights", ["The Weeknd"])],
        "v3": [],  # nothing found
    }


def test_fresh_run_matches_and_applies(tmp_path: Path, sources, catalog):
    target = FakeSpotifyTarget(catalog)
    run = ConversionRun(target=target, state_dir=tmp_path)
    run_state = RunState(playlist_id="pl1")
    state_path = tmp_path / "state.json"

    results = run.match_tracks(sources, run_state, state_path=state_path)
    statuses = {r.source.video_id: r.status for r in results}
    assert statuses["v1"] == MatchStatus.MATCHED
    assert statuses["v2"] == MatchStatus.MATCHED
    assert statuses["v3"] == MatchStatus.NOT_FOUND

    playlist_id, added = run.apply_to_spotify(
        results,
        playlist_name="Test Playlist",
        description="desc",
        public=False,
        run_state=run_state,
        state_path=state_path,
    )
    assert added == 2
    assert set(target.playlists[playlist_id]) == {
        "spotify:track:yellow",
        "spotify:track:bl",
    }


def test_state_saved_incrementally(tmp_path: Path, sources, catalog):
    """Every track's outcome must hit disk immediately, not just at the end."""
    target = FakeSpotifyTarget(catalog)
    run = ConversionRun(target=target, state_dir=tmp_path)
    run_state = RunState(playlist_id="pl1")
    state_path = tmp_path / "state.json"

    seen_counts = []

    def progress_cb(i, total, result):
        # Re-read from disk on every callback to prove the save already happened.
        on_disk = load_state(state_path, "pl1")
        seen_counts.append(len(on_disk.tracks))

    run.match_tracks(sources, run_state, progress_cb=progress_cb, state_path=state_path)
    assert seen_counts == [1, 2, 3]


def test_resume_after_crash_before_apply_still_adds_tracks(tmp_path: Path, sources, catalog):
    """Regression test: a crash between matching and applying must not lose tracks.

    Simulates: run 1 matches all tracks (state says MATCHED for v1/v2) but the
    process dies before apply_to_spotify ever runs, so nothing was actually
    added to Spotify yet. Run 2 resumes from that state; the matched tracks
    must still make it into the destination playlist.
    """
    target = FakeSpotifyTarget(catalog)
    run = ConversionRun(target=target, state_dir=tmp_path)
    state_path = tmp_path / "state.json"

    # --- Run 1: match only, "crash" before apply ---
    run_state_1 = RunState(playlist_id="pl1")
    run.match_tracks(sources, run_state_1, state_path=state_path)
    # Nothing applied yet.
    assert target.playlists == {}

    # --- Run 2: resume from disk ---
    run_state_2 = load_state(state_path, "pl1")
    results_2 = run.match_tracks(sources, run_state_2, state_path=state_path)
    # v1/v2 were MATCHED (a settled decision) so they must not be re-searched;
    # v3 was NOT_FOUND, which isn't "settled" -- it's retried in case the
    # catalog changed (cheap: SearchCache would dedupe the real network hit).
    assert target.search_calls == ["v1", "v2", "v3", "v3"]

    matched = [r for r in results_2 if r.status == MatchStatus.MATCHED]
    assert len(matched) == 2
    # This is the crux of the regression: candidates must have been
    # reconstructed from the saved state, not left as None.
    assert all(r.candidate is not None for r in matched)

    playlist_id, added = run.apply_to_spotify(
        results_2,
        playlist_name="Test Playlist",
        description="desc",
        public=False,
        run_state=run_state_2,
        state_path=state_path,
    )
    assert added == 2
    assert set(target.playlists[playlist_id]) == {
        "spotify:track:yellow",
        "spotify:track:bl",
    }


def test_resume_skips_duplicate_add_when_already_applied(tmp_path: Path, sources, catalog):
    """If run 1 fully completed (matched AND applied), run 2 must not re-add."""
    target = FakeSpotifyTarget(catalog)
    run = ConversionRun(target=target, state_dir=tmp_path)
    state_path = tmp_path / "state.json"

    run_state_1 = RunState(playlist_id="pl1")
    results_1 = run.match_tracks(sources, run_state_1, state_path=state_path)
    run.apply_to_spotify(
        results_1,
        playlist_name="Test Playlist",
        description="desc",
        public=False,
        run_state=run_state_1,
        state_path=state_path,
    )
    calls_after_run1 = len(target.search_calls)

    run_state_2 = load_state(state_path, "pl1")
    results_2 = run.match_tracks(sources, run_state_2, state_path=state_path)
    # v1/v2 (MATCHED) aren't re-searched; only v3 (NOT_FOUND) is retried.
    assert len(target.search_calls) == calls_after_run1 + 1

    playlist_id, added = run.apply_to_spotify(
        results_2,
        playlist_name="Test Playlist",
        description="desc",
        public=False,
        run_state=run_state_2,
        state_path=state_path,
    )
    assert added == 0  # both already present -> skipped as duplicates
    assert len(target.playlists[playlist_id]) == 2  # not doubled up
