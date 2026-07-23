"""Retry with exponential backoff for flaky/rate-limited API calls."""

from __future__ import annotations

import logging
import time
from functools import wraps
from typing import Callable, TypeVar

logger = logging.getLogger("playlist_converter")

T = TypeVar("T")


def with_retry(
    max_attempts: int = 5,
    base_delay: float = 1.0,
    max_delay: float = 30.0,
    retry_on: tuple[type[Exception], ...] = (Exception,),
    should_retry: Callable[[Exception], bool] | None = None,
) -> Callable[[Callable[..., T]], Callable[..., T]]:
    """Decorator that retries a function with exponential backoff + jitter.

    Honors a `retry_after` attribute/seconds hint on the raised exception
    when present (e.g. Spotify's 429 responses), otherwise backs off
    base_delay * 2**attempt, capped at max_delay.

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
                    if attempt >= max_attempts:
                        raise
                    delay = min(base_delay * (2 ** (attempt - 1)), max_delay)
                    retry_after = getattr(exc, "headers", {}) or {}
                    header_delay = None
                    if hasattr(retry_after, "get"):
                        header_delay = retry_after.get("Retry-After")
                    if header_delay is not None:
                        try:
                            delay = max(delay, float(header_delay))
                        except (TypeError, ValueError):
                            pass
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
