"""Configuration loading for the converter.

Credentials are pulled from environment variables (optionally loaded from a
.env file) so nothing sensitive ever needs to be passed on the command line
or hard-coded into source, unlike several of the existing open-source
converters that expect keys to be pasted directly into a script.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


class ConfigError(RuntimeError):
    """Raised when required configuration is missing or invalid."""


@dataclass
class SpotifyConfig:
    client_id: str
    client_secret: str
    redirect_uri: str


@dataclass
class AppConfig:
    spotify: SpotifyConfig
    ytmusic_auth_file: str | None
    youtube_api_key: str | None
    cache_path: Path
    state_dir: Path


def _load_dotenv(env_file: Path | None) -> None:
    try:
        from dotenv import load_dotenv
    except ImportError:
        return
    if env_file and env_file.exists():
        load_dotenv(env_file)
    else:
        load_dotenv()


def load_config(env_file: str | Path | None = None) -> AppConfig:
    """Load configuration from environment variables / a .env file.

    Raises ConfigError with an actionable message if required Spotify
    credentials are missing.
    """
    _load_dotenv(Path(env_file) if env_file else None)

    client_id = os.environ.get("SPOTIFY_CLIENT_ID", "").strip()
    client_secret = os.environ.get("SPOTIFY_CLIENT_SECRET", "").strip()
    redirect_uri = os.environ.get(
        "SPOTIFY_REDIRECT_URI", "http://127.0.0.1:8080/callback"
    ).strip()

    missing = [
        name
        for name, value in (
            ("SPOTIFY_CLIENT_ID", client_id),
            ("SPOTIFY_CLIENT_SECRET", client_secret),
        )
        if not value
    ]
    if missing:
        raise ConfigError(
            "Missing required Spotify credentials: "
            + ", ".join(missing)
            + ".\nRun 'playlist-converter setup' for step-by-step instructions, "
            "or copy .env.example to .env and fill it in."
        )

    ytmusic_auth_file = os.environ.get("YTMUSIC_AUTH_FILE", "").strip() or None
    youtube_api_key = os.environ.get("YOUTUBE_API_KEY", "").strip() or None

    app_dir = Path(
        os.environ.get(
            "PLAYLIST_CONVERTER_HOME", Path.home() / ".playlist-converter"
        )
    )
    app_dir.mkdir(parents=True, exist_ok=True)

    return AppConfig(
        spotify=SpotifyConfig(
            client_id=client_id,
            client_secret=client_secret,
            redirect_uri=redirect_uri,
        ),
        ytmusic_auth_file=ytmusic_auth_file,
        youtube_api_key=youtube_api_key,
        cache_path=app_dir / "search_cache.sqlite3",
        state_dir=app_dir / "state",
    )
