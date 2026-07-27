"""Tests for the official YouTube Data API v3 fallback source."""

from __future__ import annotations

from playlist_converter.youtube_data_api_source import (
    YouTubeDataApiSource,
    parse_iso8601_duration,
    parse_title_artist,
)


def test_parse_title_artist_splits_on_hyphen():
    title, artists = parse_title_artist("Coldplay - Yellow")
    assert title == "Yellow"
    assert artists == ["Coldplay"]


def test_parse_title_artist_splits_on_en_dash():
    title, artists = parse_title_artist("The Weeknd – Blinding Lights (Official Video)")
    assert title == "Blinding Lights"
    assert artists == ["The Weeknd"]


def test_parse_title_artist_falls_back_to_topic_channel():
    title, artists = parse_title_artist("Yellow", channel_title="Coldplay - Topic")
    assert title == "Yellow"
    assert artists == ["Coldplay"]


def test_parse_title_artist_falls_back_to_plain_channel():
    title, artists = parse_title_artist("Yellow (Official Video)", channel_title="Coldplay Official")
    assert title == "Yellow"
    assert artists == ["Coldplay Official"]


def test_parse_title_artist_no_artist_available():
    title, artists = parse_title_artist("Some Video Title", channel_title="")
    assert title == "Some Video Title"
    assert artists == []


def test_parse_iso8601_duration_minutes_seconds():
    assert parse_iso8601_duration("PT3M45S") == 225


def test_parse_iso8601_duration_hours_minutes_seconds():
    assert parse_iso8601_duration("PT1H2M3S") == 3723


def test_parse_iso8601_duration_seconds_only():
    assert parse_iso8601_duration("PT45S") == 45


def test_parse_iso8601_duration_invalid_returns_none():
    assert parse_iso8601_duration("not-a-duration") is None
    assert parse_iso8601_duration("") is None


class FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self):
        pass

    def json(self):
        return self._payload


class FakeSession:
    """Stands in for requests.Session, dispatching by endpoint + pageToken."""

    def __init__(self):
        self.calls: list[tuple[str, dict]] = []

    def get(self, url, params, timeout):
        self.calls.append((url, dict(params)))
        if url.endswith("/playlists"):
            return FakeResponse({"items": [{"snippet": {"title": "My Test Mix"}}]})
        if url.endswith("/playlistItems"):
            if params.get("pageToken") is None:
                return FakeResponse(
                    {
                        "items": [
                            {
                                "snippet": {
                                    "title": "Coldplay - Yellow",
                                    "resourceId": {"videoId": "v1"},
                                    "videoOwnerChannelTitle": "Coldplay",
                                }
                            },
                            {
                                "snippet": {
                                    "title": "Private video",
                                    "resourceId": {"videoId": "v2"},
                                }
                            },
                        ],
                        "nextPageToken": "page2",
                    }
                )
            return FakeResponse(
                {
                    "items": [
                        {
                            "snippet": {
                                "title": "Blinding Lights",
                                "resourceId": {"videoId": "v3"},
                                "videoOwnerChannelTitle": "The Weeknd - Topic",
                            }
                        }
                    ]
                }
            )
        if url.endswith("/videos"):
            return FakeResponse(
                {
                    "items": [
                        {"id": "v1", "contentDetails": {"duration": "PT4M27S"}},
                        {"id": "v3", "contentDetails": {"duration": "PT3M20S"}},
                    ]
                }
            )
        raise AssertionError(f"unexpected url: {url}")


def test_fetch_playlist_paginates_and_skips_unavailable():
    session = FakeSession()
    source = YouTubeDataApiSource(api_key="fake-key", session=session)

    fetched = source.fetch_playlist("PLsomeplaylist")

    assert fetched.title == "My Test Mix"
    assert fetched.unavailable_count == 1  # the "Private video" entry
    assert len(fetched.tracks) == 2

    by_id = {t.video_id: t for t in fetched.tracks}
    assert by_id["v1"].title == "Yellow"
    assert by_id["v1"].artists == ["Coldplay"]
    assert by_id["v1"].duration_seconds == 267

    assert by_id["v3"].title == "Blinding Lights"
    assert by_id["v3"].artists == ["The Weeknd"]  # from "<Artist> - Topic" channel
    assert by_id["v3"].duration_seconds == 200

    # Every request must carry the API key.
    assert all(call[1]["key"] == "fake-key" for call in session.calls)


def test_fetch_playlist_all_unavailable_skips_duration_call():
    class EmptySession(FakeSession):
        def get(self, url, params, timeout):
            self.calls.append((url, dict(params)))
            if url.endswith("/playlists"):
                return FakeResponse({"items": [{"snippet": {"title": "Empty"}}]})
            if url.endswith("/playlistItems"):
                return FakeResponse(
                    {"items": [{"snippet": {"title": "Deleted video", "resourceId": {}}}]}
                )
            raise AssertionError(f"unexpected url: {url}")

    session = EmptySession()
    source = YouTubeDataApiSource(api_key="fake-key", session=session)
    fetched = source.fetch_playlist("PLempty")

    assert fetched.tracks == []
    assert fetched.unavailable_count == 1
    assert not any(url.endswith("/videos") for url, _ in session.calls)
