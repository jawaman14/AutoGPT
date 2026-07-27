import pytest

from playlist_converter.youtube_source import PlaylistNotFoundError, parse_playlist_id


def test_parse_bare_playlist_id():
    assert parse_playlist_id("PL1234567890abcdef") == "PL1234567890abcdef"


def test_parse_youtube_music_url():
    url = "https://music.youtube.com/playlist?list=PLabc123"
    assert parse_playlist_id(url) == "PLabc123"


def test_parse_youtube_url_with_extra_params():
    url = "https://www.youtube.com/playlist?list=PLabc123&si=xyz"
    assert parse_playlist_id(url) == "PLabc123"


def test_parse_invalid_input_raises():
    with pytest.raises(PlaylistNotFoundError):
        parse_playlist_id("https://music.youtube.com/watch?v=abc")
