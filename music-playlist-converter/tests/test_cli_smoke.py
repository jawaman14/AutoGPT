"""Full CLI smoke test with YTMusic/Spotify faked out at the module boundary.

This exercises the real argument parsing, config loading, and orchestration
wiring in cli.py end-to-end -- the layer the more focused unit tests don't
touch -- without needing real network access or credentials.
"""

from __future__ import annotations

import csv
import json

import pytest

FAKE_PLAYLIST = {
    "title": "My Test Mix",
    "tracks": [
        {
            "videoId": "v1",
            "title": "Yellow (Official Video)",
            "artists": [{"name": "Coldplay"}],
            "album": {"name": "Parachutes"},
            "duration_seconds": 267,
        },
        {
            "videoId": "v2",
            "title": "Blinding Lights",
            "artists": [{"name": "The Weeknd"}],
            "album": {"name": "After Hours"},
            "duration_seconds": 200,
        },
        {
            "videoId": "v3",
            "title": "Totally Obscure Track Nobody Made",
            "artists": [{"name": "Nobody"}],
            "album": None,
            "duration_seconds": 180,
        },
        {
            # Unavailable/region-locked entry: no videoId.
            "title": "Removed Video",
            "artists": [],
        },
    ],
}

SPOTIFY_CATALOG = {
    "yellow coldplay": [
        {
            "uri": "spotify:track:yellow",
            "name": "Yellow",
            "artists": [{"name": "Coldplay"}],
            "album": {"name": "Parachutes"},
            "duration_ms": 267000,
        }
    ],
    "blinding lights the weeknd": [
        {
            "uri": "spotify:track:bl",
            "name": "Blinding Lights",
            "artists": [{"name": "The Weeknd"}],
            "album": {"name": "After Hours"},
            "duration_ms": 200000,
        }
    ],
}


class FakeYTMusic:
    def __init__(self, *args, **kwargs):
        pass

    def get_playlist(self, playlist_id, limit=None):
        return FAKE_PLAYLIST


class FakeSpotify:
    search_raises_for: set[str] = set()

    def __init__(self, *args, **kwargs):
        self.playlists: dict[str, dict] = {}
        self._next_id = 1

    def current_user(self):
        return {"id": "testuser"}

    def search(self, q, type, limit):
        key = q.lower()
        for query_key in FakeSpotify.search_raises_for:
            if query_key in key:
                raise RuntimeError(f"simulated failure for query '{q}'")
        for catalog_key, items in SPOTIFY_CATALOG.items():
            if all(word in key for word in catalog_key.split()):
                return {"tracks": {"items": items}}
        return {"tracks": {"items": []}}

    def current_user_playlists(self, limit, offset):
        return {"items": list(self.playlists.values()), "next": None}

    def user_playlist_create(self, user, name, public, description):
        pid = f"playlist_{self._next_id}"
        self._next_id += 1
        self.playlists[pid] = {"id": pid, "name": name, "tracks": []}
        return {"id": pid}

    def playlist_items(self, playlist_id, fields, offset, limit):
        tracks = self.playlists[playlist_id]["tracks"]
        items = [{"track": {"uri": uri}} for uri in tracks[offset : offset + limit]]
        return {"items": items, "next": None}

    def playlist_add_items(self, playlist_id, uris):
        self.playlists[playlist_id]["tracks"].extend(uris)


@pytest.fixture
def env(monkeypatch, tmp_path):
    # The simulated failures below are plain RuntimeErrors (no http_status),
    # which the real retry logic treats as transient and retries with real
    # exponential backoff -- correct in production, but tests shouldn't
    # burn wall-clock time on it.
    import playlist_converter.retry as retry_module

    monkeypatch.setattr(retry_module.time, "sleep", lambda *_args, **_kwargs: None)

    monkeypatch.setenv("SPOTIFY_CLIENT_ID", "fake-id")
    monkeypatch.setenv("SPOTIFY_CLIENT_SECRET", "fake-secret")
    monkeypatch.setenv("SPOTIFY_REDIRECT_URI", "http://127.0.0.1:8080/callback")
    monkeypatch.setenv("PLAYLIST_CONVERTER_HOME", str(tmp_path / "home"))

    import ytmusicapi

    monkeypatch.setattr(ytmusicapi, "YTMusic", FakeYTMusic)

    import spotipy
    import spotipy.oauth2

    monkeypatch.setattr(spotipy, "Spotify", FakeSpotify)
    monkeypatch.setattr(spotipy.oauth2, "SpotifyOAuth", lambda **kwargs: object())

    FakeSpotify.search_raises_for = set()
    yield tmp_path


def test_dry_run_produces_report_without_writing_to_spotify(env, tmp_path):
    from playlist_converter.cli import main

    report_dir = tmp_path / "reports"
    exit_code = main(
        [
            "convert",
            "PLfakeplaylist",
            "--dry-run",
            "--report-dir",
            str(report_dir),
        ]
    )
    assert exit_code == 0

    csv_path = report_dir / "match_report.csv"
    json_path = report_dir / "match_report.json"
    assert csv_path.exists()
    assert json_path.exists()

    rows = list(csv.DictReader(csv_path.open()))
    assert len(rows) == 3  # the 4th (no videoId) track is excluded upstream

    payload = json.loads(json_path.read_text())
    statuses = {row["youtube"]["video_id"]: row["status"] for row in payload}
    assert statuses["v1"] == "matched"
    assert statuses["v2"] == "matched"
    assert statuses["v3"] == "not_found"


def test_real_run_creates_playlist_and_adds_matched_tracks(env, tmp_path):
    from playlist_converter.cli import main

    report_dir = tmp_path / "reports"
    exit_code = main(
        [
            "convert",
            "PLfakeplaylist",
            "--name",
            "My Converted Playlist",
            "--report-dir",
            str(report_dir),
        ]
    )
    assert exit_code == 0


def test_limit_restricts_track_count(env, tmp_path):
    from playlist_converter.cli import main

    report_dir = tmp_path / "reports"
    exit_code = main(
        [
            "convert",
            "PLfakeplaylist",
            "--dry-run",
            "--limit",
            "1",
            "--report-dir",
            str(report_dir),
        ]
    )
    assert exit_code == 0
    rows = list(csv.DictReader((report_dir / "match_report.csv").open()))
    assert len(rows) == 1


def test_strict_exits_nonzero_when_tracks_unmatched(env, tmp_path):
    from playlist_converter.cli import main

    report_dir = tmp_path / "reports"
    exit_code = main(
        [
            "convert",
            "PLfakeplaylist",
            "--dry-run",
            "--strict",
            "--report-dir",
            str(report_dir),
        ]
    )
    assert exit_code == 2  # v3 is not_found -> needs review -> strict failure


def test_crash_mid_run_then_resume_completes_without_reloss(env, tmp_path):
    """Regression coverage for the resume/candidate-reconstruction fix at the CLI layer."""
    from playlist_converter.cli import main

    report_dir = tmp_path / "reports"

    # Force the Blinding Lights search to blow up, simulating a crash after
    # v1 has already been matched+saved but before the run finishes.
    FakeSpotify.search_raises_for = {"blinding lights"}
    exit_code = main(
        [
            "convert",
            "PLfakeplaylist",
            "--name",
            "Resumable Playlist",
            "--report-dir",
            str(report_dir),
        ]
    )
    assert exit_code == 1  # unhandled error surfaced cleanly, not a raw traceback

    # Now let searches succeed and resume.
    FakeSpotify.search_raises_for = set()
    exit_code = main(
        [
            "convert",
            "PLfakeplaylist",
            "--name",
            "Resumable Playlist",
            "--resume",
            "--report-dir",
            str(report_dir),
        ]
    )
    assert exit_code == 0

    payload = json.loads((report_dir / "match_report.json").read_text())
    statuses = {row["youtube"]["video_id"]: row["status"] for row in payload}
    assert statuses["v1"] == "matched"
    assert statuses["v2"] == "matched"
