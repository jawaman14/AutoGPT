"""Reads playlist tracks via the official YouTube Data API v3.

ytmusicapi (the default source) talks to music.youtube.com's unofficial
internal API. Some networks -- corporate proxies, certain sandboxes --
block that consumer-facing domain outright while still allowing the
officially documented googleapis.com surface. This is a fallback for
exactly that situation.

Trade-off: it needs a free API key
(https://console.cloud.google.com/apis/credentials, enable "YouTube Data
API v3"), and because regular YouTube playlist metadata doesn't carry the
structured artist/album fields YT Music playlists do, the artist is
guessed heuristically from the video title/channel -- match accuracy is
usually a bit lower than the default source.
"""

from __future__ import annotations

import re
from typing import Iterable

from .models import SourceTrack
from .retry import with_retry
from .text_utils import strip_noise
from .youtube_source import FetchedPlaylist, PlaylistNotFoundError, parse_playlist_id

API_BASE = "https://www.googleapis.com/youtube/v3"
PAGE_SIZE = 50
_TITLE_SPLIT_RE = re.compile(r"\s+[-–—]\s+")  # hyphen, en dash, em dash
_UNAVAILABLE_TITLES = {"private video", "deleted video"}
_DURATION_RE = re.compile(r"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$")


def _is_retryable(exc: Exception) -> bool:
    status = getattr(exc, "status_code", None)
    if status is None:
        response = getattr(exc, "response", None)
        status = getattr(response, "status_code", None)
    if status is None:
        return True  # connection-level error (timeout, DNS, etc.): worth retrying
    return status == 429 or status >= 500


_api_retry = with_retry(max_attempts=4, base_delay=2.0, should_retry=_is_retryable)


def parse_title_artist(raw_title: str, channel_title: str = "") -> tuple[str, list[str]]:
    """Heuristic split of a plain YouTube video title into (title, artists).

    Regular YouTube video titles for music are conventionally
    "Artist - Title" (with various dash characters), but there's no
    guarantee. Falls back to the uploader/channel name as a weak artist
    guess -- including recognizing YouTube's auto-generated "<Artist> -
    Topic" channels for official audio uploads -- and finally to just the
    cleaned title with no known artist.
    """
    cleaned = strip_noise(raw_title)
    parts = _TITLE_SPLIT_RE.split(cleaned, maxsplit=1)
    if len(parts) == 2 and all(p.strip() for p in parts):
        artist, title = parts
        return title.strip(), [artist.strip()]

    channel = channel_title.strip()
    if channel.lower().endswith("- topic"):
        return cleaned, [channel.rsplit("-", 1)[0].strip()]
    if channel:
        return cleaned, [channel]
    return cleaned, []


def parse_iso8601_duration(duration: str) -> int | None:
    match = _DURATION_RE.match(duration or "")
    if not match:
        return None
    hours, minutes, seconds = (int(g) if g else 0 for g in match.groups())
    return hours * 3600 + minutes * 60 + seconds


class YouTubeDataApiSource:
    def __init__(self, api_key: str, session=None):
        import requests

        self._api_key = api_key
        self._session = session or requests.Session()

    @_api_retry
    def _get(self, path: str, params: dict) -> dict:
        response = self._session.get(
            f"{API_BASE}/{path}", params={**params, "key": self._api_key}, timeout=15
        )
        response.raise_for_status()
        return response.json()

    def _iter_playlist_items(self, playlist_id: str) -> Iterable[dict]:
        page_token = None
        while True:
            params = {"part": "snippet", "playlistId": playlist_id, "maxResults": PAGE_SIZE}
            if page_token:
                params["pageToken"] = page_token
            data = self._get("playlistItems", params)
            yield from data.get("items", [])
            page_token = data.get("nextPageToken")
            if not page_token:
                return

    def _fetch_durations(self, video_ids: list[str]) -> dict[str, int]:
        durations: dict[str, int] = {}
        for i in range(0, len(video_ids), PAGE_SIZE):
            batch = video_ids[i : i + PAGE_SIZE]
            if not batch:
                continue
            data = self._get("videos", {"part": "contentDetails", "id": ",".join(batch)})
            for item in data.get("items", []):
                seconds = parse_iso8601_duration(
                    item.get("contentDetails", {}).get("duration", "")
                )
                if seconds is not None:
                    durations[item["id"]] = seconds
        return durations

    def _fetch_playlist_title(self, playlist_id: str) -> str | None:
        data = self._get("playlists", {"part": "snippet", "id": playlist_id})
        items = data.get("items", [])
        if not items:
            return None
        return items[0].get("snippet", {}).get("title")

    def fetch_playlist(self, playlist_id_or_url: str) -> FetchedPlaylist:
        playlist_id = parse_playlist_id(playlist_id_or_url)
        try:
            items = list(self._iter_playlist_items(playlist_id))
            title = self._fetch_playlist_title(playlist_id) or "Untitled Playlist"
        except Exception as exc:  # noqa: BLE001
            raise PlaylistNotFoundError(
                f"Failed to fetch playlist '{playlist_id}' via the YouTube Data API: {exc}\n"
                "Check that the playlist is public and that your API key is valid "
                "and has the YouTube Data API v3 enabled."
            ) from exc

        pending: list[dict] = []
        unavailable_count = 0
        for item in items:
            snippet = item.get("snippet", {})
            raw_title = snippet.get("title", "")
            video_id = (snippet.get("resourceId") or {}).get("videoId")
            if not video_id or raw_title.strip().lower() in _UNAVAILABLE_TITLES:
                unavailable_count += 1
                continue
            pending.append(
                {
                    "video_id": video_id,
                    "raw_title": raw_title,
                    "channel_title": snippet.get("videoOwnerChannelTitle", ""),
                }
            )

        durations = self._fetch_durations([p["video_id"] for p in pending])

        tracks: list[SourceTrack] = []
        for p in pending:
            title_clean, artists = parse_title_artist(p["raw_title"], p["channel_title"])
            tracks.append(
                SourceTrack(
                    video_id=p["video_id"],
                    title=title_clean or p["raw_title"],
                    artists=artists,
                    album=None,
                    duration_seconds=durations.get(p["video_id"]),
                )
            )
        return FetchedPlaylist(title=title, tracks=tracks, unavailable_count=unavailable_count)
