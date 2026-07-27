"""Text normalization helpers used to improve fuzzy-match accuracy.

YouTube Music titles are full of noise that Spotify's catalog never has
("(Official Video)", "[4K Remaster]", "feat. X", etc.). Stripping that noise
before scoring is the single biggest lever for match quality, so it lives in
its own testable module rather than being inlined into the matcher.
"""

from __future__ import annotations

import re

_NOISE_PATTERNS = [
    r"\(official\s*(music\s*)?video\)",
    r"\(official\s*audio\)",
    r"\(official\)",
    r"\(lyrics?\s*video?\)",
    r"\(lyrics?\)",
    r"\(visualizer\)",
    r"\(audio\)",
    r"\[official\s*(music\s*)?video\]",
    r"\[official\s*audio\]",
    r"\[lyrics?\s*video?\]",
    r"\[audio\]",
    r"\(hd\)",
    r"\(hq\)",
    r"\[hd\]",
    r"\[hq\]",
    r"\(\d{4}\s*remaster(ed)?\)",
    r"\[\d{4}\s*remaster(ed)?\]",
    r"\(remaster(ed)?\)",
    r"\[remaster(ed)?\]",
    r"\(clean\)",
    r"\(explicit\)",
    r"\(mv\)",
    r"\[mv\]",
]
_NOISE_RE = re.compile("|".join(_NOISE_PATTERNS), re.IGNORECASE)
# \b is anchored right after the bare keyword (before any trailing dot) so it
# reliably matches a word/non-word boundary; the dot itself is consumed
# separately since "feat." would otherwise straddle the boundary check.
_FEAT_KEYWORD = r"(?:feat|featuring|ft)\b\.?"
_FEAT_RE = re.compile(
    rf"\s*[\(\[]?\b{_FEAT_KEYWORD}\s*[^\)\]\-]*[\)\]]?", re.IGNORECASE
)
_FEAT_PREFIX_RE = re.compile(rf"^[\s\(\[]*\b{_FEAT_KEYWORD}\s*", re.IGNORECASE)
_MULTI_SPACE_RE = re.compile(r"\s+")
_NON_ALNUM_RE = re.compile(r"[^\w\s]", re.UNICODE)
_APOSTROPHE_RE = re.compile(r"['’]")


def strip_noise(text: str) -> str:
    """Remove common "(Official Video)"-style decorations from a title."""
    text = _NOISE_RE.sub("", text)
    text = _FEAT_RE.sub("", text)
    return _MULTI_SPACE_RE.sub(" ", text).strip()


def normalize(text: str) -> str:
    """Lowercase, strip noise/punctuation, collapse whitespace.

    Used to build the cache key and as a last-resort comparison basis; the
    fuzzy matcher itself works on the lightly-cleaned (non-normalized)
    strings so it can still weigh word order and partial overlaps.
    """
    text = strip_noise(text)
    text = text.lower()
    text = _APOSTROPHE_RE.sub("", text)
    text = _NON_ALNUM_RE.sub(" ", text)
    return _MULTI_SPACE_RE.sub(" ", text).strip()


def extract_featured_artists(title: str) -> list[str]:
    """Pull featured-artist names out of a title, e.g. 'Song (feat. X & Y)'."""
    match = _FEAT_RE.search(title)
    if not match:
        return []
    raw = match.group(0)
    raw = _FEAT_PREFIX_RE.sub("", raw)
    raw = raw.strip(" )]-")
    if not raw:
        return []
    parts = re.split(r",|&|\band\b", raw, flags=re.IGNORECASE)
    return [p.strip() for p in parts if p.strip()]
