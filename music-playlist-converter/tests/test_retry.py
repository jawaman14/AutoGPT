"""Tests for the retry/backoff decorator, especially the Retry-After ceiling.

Regression coverage for a real bug hit in production use: Spotify returned a
429 with Retry-After: 86011 (roughly 24 hours) when the app hit its overall
quota, and the retry logic slept through it verbatim -- hanging a foreground
CLI run for a full day instead of failing fast with a resumable message.
"""

from __future__ import annotations

import pytest

from playlist_converter.retry import RetryAfterTooLong, format_duration, with_retry


class FakeHttpError(Exception):
    def __init__(self, message="rate limited", retry_after=None):
        super().__init__(message)
        self.headers = {"Retry-After": retry_after} if retry_after is not None else {}


def test_format_duration_hours_minutes():
    assert format_duration(86011) == "23h 53m"


def test_format_duration_seconds_only():
    assert format_duration(45) == "45s"


def test_format_duration_minutes_only():
    assert format_duration(120) == "2m"


def test_format_duration_minutes_and_seconds():
    assert format_duration(125) == "2m 5s"


def test_succeeds_after_transient_failures(monkeypatch):
    monkeypatch.setattr("playlist_converter.retry.time.sleep", lambda *_: None)
    calls = {"count": 0}

    @with_retry(max_attempts=3, base_delay=0.01)
    def flaky():
        calls["count"] += 1
        if calls["count"] < 3:
            raise FakeHttpError()
        return "ok"

    assert flaky() == "ok"
    assert calls["count"] == 3


def test_gives_up_after_max_attempts(monkeypatch):
    monkeypatch.setattr("playlist_converter.retry.time.sleep", lambda *_: None)

    @with_retry(max_attempts=2, base_delay=0.01)
    def always_fails():
        raise FakeHttpError("nope")

    with pytest.raises(FakeHttpError):
        always_fails()


def test_should_retry_filter_skips_retry_entirely(monkeypatch):
    slept = []
    monkeypatch.setattr("playlist_converter.retry.time.sleep", lambda s: slept.append(s))

    @with_retry(max_attempts=5, base_delay=0.01, should_retry=lambda exc: False)
    def permanent_failure():
        raise FakeHttpError("bad credentials")

    with pytest.raises(FakeHttpError):
        permanent_failure()
    assert slept == []


def test_small_retry_after_is_honored_and_slept(monkeypatch):
    slept = []
    monkeypatch.setattr("playlist_converter.retry.time.sleep", lambda s: slept.append(s))
    calls = {"count": 0}

    @with_retry(max_attempts=3, base_delay=0.01, max_wait=120)
    def rate_limited_once():
        calls["count"] += 1
        if calls["count"] == 1:
            raise FakeHttpError("slow down", retry_after="5")
        return "ok"

    assert rate_limited_once() == "ok"
    assert slept == [5.0]


def test_large_retry_after_raises_instead_of_sleeping(monkeypatch):
    """The exact regression: a ~24h Retry-After must not be slept through."""
    slept = []
    monkeypatch.setattr("playlist_converter.retry.time.sleep", lambda s: slept.append(s))

    @with_retry(max_attempts=5, base_delay=0.01, max_wait=120)
    def app_quota_exhausted():
        raise FakeHttpError("app rate limit", retry_after="86011")

    with pytest.raises(RetryAfterTooLong) as exc_info:
        app_quota_exhausted()

    assert slept == []  # never slept even once
    assert exc_info.value.seconds == 86011.0
    assert "23h 53m" in str(exc_info.value)


def test_large_retry_after_raises_even_on_first_attempt(monkeypatch):
    """No point burning even one retry cycle when the wait is this long."""
    slept = []
    monkeypatch.setattr("playlist_converter.retry.time.sleep", lambda s: slept.append(s))
    calls = {"count": 0}

    @with_retry(max_attempts=10, base_delay=0.01, max_wait=120)
    def quota_exhausted():
        calls["count"] += 1
        raise FakeHttpError("app rate limit", retry_after="3600")

    with pytest.raises(RetryAfterTooLong):
        quota_exhausted()

    assert calls["count"] == 1  # failed fast, didn't loop
    assert slept == []
