from pathlib import Path

from playlist_converter.cache import SearchCache


def test_cache_roundtrip(tmp_path: Path):
    cache = SearchCache(tmp_path / "cache.sqlite3")
    assert cache.get("missing") is None

    cache.set("song|artist", [{"uri": "spotify:track:1"}])
    assert cache.get("song|artist") == [{"uri": "spotify:track:1"}]
    cache.close()


def test_cache_persists_across_instances(tmp_path: Path):
    path = tmp_path / "cache.sqlite3"
    cache1 = SearchCache(path)
    cache1.set("key", [{"a": 1}])
    cache1.close()

    cache2 = SearchCache(path)
    assert cache2.get("key") == [{"a": 1}]
    cache2.close()


def test_cache_clear(tmp_path: Path):
    cache = SearchCache(tmp_path / "cache.sqlite3")
    cache.set("key", [{"a": 1}])
    cache.clear()
    assert cache.get("key") is None
    cache.close()
