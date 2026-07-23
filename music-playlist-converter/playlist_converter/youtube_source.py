"""Reads tracks from a YouTube Music playlist.

Unlike converters built on the official YouTube Data API, this uses
ytmusicapi, which can read *public* playlists with zero credentials and no
Google Cloud project/API key setup. Private playlists still work if the
user points --yt-auth-file at a ytmusicapi auth file (see README).
"""

from __future__ import annotations

import re
from urllib.parse import parse_qs, urlparse

from .models import SourceTrack
from .retry import with_retry

_PLAYLIST_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")


class PlaylistNotFoundError(RuntimeError):
    pass


def parse_playlist_id(raw: str) -> str:
    """Accept a bare playlist ID, a youtube.com URL, or a music.youtube.com URL."""
    raw = raw.strip()
    if _PLAYLIST_ID_RE.match(raw) and "." not in raw and "/" not in raw:
        return raw

    parsed = urlparse(raw)
    query = parse_qs(parsed.query)
    if "list" in query and query["list"]:
        return query["list"][0]

    raise PlaylistNotFoundError(
        f"Could not extract a playlist ID from '{raw}'. Pass either the "
        "playlist ID itself or a full YouTube/YouTube Music playlist URL."
    )


class YouTubeMusicSource:
    def __init__(self, auth_file: str | None = None):
        from ytmusicapi import YTMusic

        # auth is only required to read private playlists / the user's
        # own library; public playlists work with an unauthenticated client.
        self._yt = YTMusic(auth_file) if auth_file else YTMusic()

    @with_retry(max_attempts=4, base_delay=2.0)
    def fetch_playlist(self, playlist_id_or_url: str) -> tuple[str, list[SourceTrack]]:
        """Return (playlist_title, tracks) for the given playlist."""
        playlist_id = parse_playlist_id(playlist_id_or_url)
        try:
            data = self._yt.get_playlist(playlist_id, limit=None)
        except Exception as exc:  # noqa: BLE001
            raise PlaylistNotFoundError(
                f"Failed to fetch playlist '{playlist_id}': {exc}\n"
                "If this is a private playlist, pass --yt-auth-file with a "
                "ytmusicapi auth file."
            ) from exc

        title = data.get("title", "Untitled Playlist")
        tracks: list[SourceTrack] = []
        for item in data.get("tracks", []):
            if not item.get("videoId"):
                continue  # unavailable/region-locked entries have no videoId
            artists = [a["name"] for a in (item.get("artists") or []) if a.get("name")]
            album = (item.get("album") or {}).get("name")
            tracks.append(
                SourceTrack(
                    video_id=item["videoId"],
                    title=item.get("title") or "Unknown Title",
                    artists=artists,
                    album=album,
                    duration_seconds=item.get("duration_seconds"),
                )
            )
        return title, tracks
