"""Retry with exponential backoff for flaky/rate-limited API calls."""

from __future__ import annotations

import logging
import time
from functools import wraps
from typing import Callable, TypeVar

logger = logging.getLogger("playlist_converter")

T = TypeVar("T")

DEFAULT_MAX_WAIT = 120.0  # never block a foreground CLI run longer than this


def format_duration(seconds: float) -> str:
    total = int(seconds)
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    parts = []
    if hours:
        parts.append(f"{hours}h")
        if minutes:
            parts.append(f"{minutes}m")
    elif minutes:
        parts.append(f"{minutes}m")
        if secs:
            parts.append(f"{secs}s")
    else:
        parts.append(f"{secs}s")
    return " ".join(parts)


class RetryAfterTooLong(RuntimeError):
    """Raised instead of sleeping when a server's Retry-After is unreasonably long.

    Some APIs (e.g. Spotify, when an app-wide quota is exhausted rather than
    a single endpoint being rate-limited) return a Retry-After measured in
    hours. Sleeping through that in a foreground CLI process would hang the
    terminal for the whole duration; failing fast with a clear message is
    better, especially since run state is checkpointed so --resume picks up
    right where this left off once the wait is over.
    """

    def __init__(self, seconds: float, original: Exception):
        self.seconds = seconds
        self.original = original
        super().__init__(
            f"Server asked to wait {format_duration(seconds)} before retrying: {original}"
        )


def with_retry(
    max_attempts: int = 5,
    base_delay: float = 1.0,
    max_delay: float = 30.0,
    retry_on: tuple[type[Exception], ...] = (Exception,),
    should_retry: Callable[[Exception], bool] | None = None,
    max_wait: float = DEFAULT_MAX_WAIT,
) -> Callable[[Callable[..., T]], Callable[..., T]]:
    """Decorator that retries a function with exponential backoff + jitter.

    Honors a `Retry-After` header hint on the raised exception when present
    (e.g. Spotify's 429 responses), otherwise backs off base_delay *
    2**attempt, capped at max_delay. If the honored Retry-After exceeds
    `max_wait`, raises RetryAfterTooLong instead of actually sleeping that
    long -- see its docstring for why.

    `should_retry`, if given, is consulted before backing off: it lets
    callers distinguish transient failures (rate limits, network blips)
    from permanent ones (bad credentials, malformed request) so the latter
    fail immediately instead of burning ~30s retrying something that will
    never succeed.
    """

    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        @wraps(func)
        def wrapper(*args, **kwargs) -> T:
            attempt = 0
            while True:
                try:
                    return func(*args, **kwargs)
                except retry_on as exc:  # noqa: BLE001 - intentional broad catch
                    if should_retry is not None and not should_retry(exc):
                        raise
                    attempt += 1
                    delay = min(base_delay * (2 ** (attempt - 1)), max_delay)

                    headers = getattr(exc, "headers", {}) or {}
                    header_delay = None
                    if hasattr(headers, "get"):
                        raw = headers.get("Retry-After")
                        if raw is not None:
                            try:
                                header_delay = float(raw)
                            except (TypeError, ValueError):
                                header_delay = None

                    if header_delay is not None and header_delay > max_wait:
                        raise RetryAfterTooLong(header_delay, exc) from exc
                    if header_delay is not None:
                        delay = max(delay, header_delay)

                    if attempt >= max_attempts:
                        raise

                    logger.warning(
                        "%s failed (attempt %d/%d): %s - retrying in %.1fs",
                        func.__name__,
                        attempt,
                        max_attempts,
                        exc,
                        delay,
                    )
                    time.sleep(delay)

        return wrapper

    return decorator
