"""Searches Spotify and manages the destination playlist."""

from __future__ import annotations

import logging

from .cache import SearchCache
from .config import SpotifyConfig
from .models import SourceTrack, SpotifyCandidate
from .retry import with_retry
from .text_utils import normalize, strip_noise

logger = logging.getLogger("playlist_converter")

ADD_TRACKS_BATCH_SIZE = 100


def _candidate_from_item(item: dict) -> SpotifyCandidate:
    return SpotifyCandidate(
        uri=item["uri"],
        title=item["name"],
        artists=[a["name"] for a in item.get("artists", [])],
        album=(item.get("album") or {}).get("name"),
        duration_seconds=(item.get("duration_ms") or 0) // 1000 or None,
    )


class SpotifyTarget:
    def __init__(self, config: SpotifyConfig, cache: SearchCache | None = None):
        import spotipy
        from spotipy.oauth2 import SpotifyOAuth

        self._sp = spotipy.Spotify(
            auth_manager=SpotifyOAuth(
                client_id=config.client_id,
                client_secret=config.client_secret,
                redirect_uri=config.redirect_uri,
                scope="playlist-modify-public playlist-modify-private",
                open_browser=True,
            )
        )
        self._cache = cache
        self._user_id: str | None = None

    @property
    def user_id(self) -> str:
        if self._user_id is None:
            self._user_id = self._sp.current_user()["id"]
        return self._user_id

    def _query_key(self, source: SourceTrack) -> str:
        clean_title = normalize(strip_noise(source.title))
        artists = normalize(source.artist_display)
        return f"{clean_title}|{artists}"

    def _build_query(self, source: SourceTrack) -> str:
        clean_title = strip_noise(source.title)
        if source.artists:
            return f"{clean_title} {source.artist_display}"
        return clean_title

    @with_retry(max_attempts=5, base_delay=2.0)
    def _raw_search(self, query: str, limit: int) -> list[dict]:
        results = self._sp.search(q=query, type="track", limit=limit)
        return results.get("tracks", {}).get("items", [])

    def search(self, source: SourceTrack, limit: int = 8) -> list[SpotifyCandidate]:
        """Search Spotify for candidates matching a source track, using the cache."""
        key = self._query_key(source)
        if self._cache is not None:
            cached = self._cache.get(key)
            if cached is not None:
                return [_candidate_from_item(item) for item in cached]

        query = self._build_query(source)
        items = self._raw_search(query, limit)

        if not items and source.artists:
            # Fall back to a title-only search: overly specific artist
            # credits (e.g. "Artist A, Artist B, Artist C") sometimes return
            # nothing even though the track exists under a simpler query.
            items = self._raw_search(strip_noise(source.title), limit)

        if self._cache is not None:
            self._cache.set(key, items)

        return [_candidate_from_item(item) for item in items]

    @with_retry(max_attempts=5, base_delay=2.0)
    def find_playlist_by_name(self, name: str) -> dict | None:
        offset = 0
        while True:
            page = self._sp.current_user_playlists(limit=50, offset=offset)
            items = page.get("items", [])
            if not items:
                return None
            for playlist in items:
                if playlist["name"] == name:
                    return playlist
            if page.get("next") is None:
                return None
            offset += 50

    @with_retry(max_attempts=5, base_delay=2.0)
    def create_playlist(self, name: str, description: str, public: bool) -> dict:
        return self._sp.user_playlist_create(
            self.user_id, name, public=public, description=description[:300]
        )

    @with_retry(max_attempts=5, base_delay=2.0)
    def get_playlist_track_uris(self, playlist_id: str) -> set[str]:
        uris: set[str] = set()
        offset = 0
        while True:
            page = self._sp.playlist_items(
                playlist_id,
                fields="items.track.uri,next",
                offset=offset,
                limit=100,
            )
            items = page.get("items", [])
            if not items:
                break
            for item in items:
                track = item.get("track") or {}
                if track.get("uri"):
                    uris.add(track["uri"])
            if page.get("next") is None:
                break
            offset += 100
        return uris

    @with_retry(max_attempts=5, base_delay=2.0)
    def _add_batch(self, playlist_id: str, uris: list[str]) -> None:
        self._sp.playlist_add_items(playlist_id, uris)

    def add_tracks(self, playlist_id: str, uris: list[str]) -> None:
        for i in range(0, len(uris), ADD_TRACKS_BATCH_SIZE):
            batch = uris[i : i + ADD_TRACKS_BATCH_SIZE]
            self._add_batch(playlist_id, batch)
            logger.info("Added %d/%d tracks", min(i + len(batch), len(uris)), len(uris))
