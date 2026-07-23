"""Tests for the --interactive low-confidence-match resolver."""

from __future__ import annotations

from playlist_converter.cli import _make_interactive_resolver
from playlist_converter.matching import score_candidate
from playlist_converter.models import SourceTrack, SpotifyCandidate


class FakeConsole:
    def print(self, *args, **kwargs):
        pass


class FakeTarget:
    def __init__(self, search_results=None):
        self.search_results = search_results or []
        self.search_queries: list[str] = []

    def search_raw_query(self, query, limit=8):
        self.search_queries.append(query)
        return self.search_results


def make_ranked(source, candidates):
    return [score_candidate(source, c) for c in candidates]


def test_resolver_picks_chosen_alternative(monkeypatch):
    source = SourceTrack(video_id="v1", title="Song", artists=["Artist"])
    candidates = [
        SpotifyCandidate("spotify:track:1", "Song (Live)", ["Cover Band"], None, None),
        SpotifyCandidate("spotify:track:2", "Song", ["Artist"], None, None),
    ]
    ranked = make_ranked(source, candidates)

    monkeypatch.setattr("playlist_converter.cli.Prompt.ask", lambda *a, **k: "2")
    resolver = _make_interactive_resolver(FakeConsole(), FakeTarget())
    chosen = resolver(source, ranked)

    assert chosen is not None
    assert chosen.candidate.uri == ranked[1].candidate.uri


def test_resolver_skip_returns_none(monkeypatch):
    source = SourceTrack(video_id="v1", title="Song", artists=["Artist"])
    candidates = [SpotifyCandidate("spotify:track:1", "Song (Live)", ["Cover Band"], None, None)]
    ranked = make_ranked(source, candidates)

    monkeypatch.setattr("playlist_converter.cli.Prompt.ask", lambda *a, **k: "0")
    resolver = _make_interactive_resolver(FakeConsole(), FakeTarget())
    assert resolver(source, ranked) is None


def test_resolver_custom_search_then_pick(monkeypatch):
    source = SourceTrack(video_id="v1", title="Song", artists=["Artist"])
    candidates = [SpotifyCandidate("spotify:track:1", "Song (Live)", ["Cover Band"], None, None)]
    ranked = make_ranked(source, candidates)

    custom_result = SpotifyCandidate("spotify:track:custom", "Song", ["Artist"], None, None)
    target = FakeTarget(search_results=[custom_result])

    answers = iter(["s", "custom search text", "1"])
    monkeypatch.setattr("playlist_converter.cli.Prompt.ask", lambda *a, **k: next(answers))

    resolver = _make_interactive_resolver(FakeConsole(), target)
    chosen = resolver(source, ranked)

    assert target.search_queries == ["custom search text"]
    assert chosen is not None
    assert chosen.candidate.uri == "spotify:track:custom"


def test_resolver_custom_search_no_results_returns_none(monkeypatch):
    source = SourceTrack(video_id="v1", title="Song", artists=["Artist"])
    candidates = [SpotifyCandidate("spotify:track:1", "Song (Live)", ["Cover Band"], None, None)]
    ranked = make_ranked(source, candidates)

    target = FakeTarget(search_results=[])
    answers = iter(["s", "nothing matches this"])
    monkeypatch.setattr("playlist_converter.cli.Prompt.ask", lambda *a, **k: next(answers))

    resolver = _make_interactive_resolver(FakeConsole(), target)
    assert resolver(source, ranked) is None
