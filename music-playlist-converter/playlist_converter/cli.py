"""Command-line interface."""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from rich.console import Console
from rich.progress import BarColumn, Progress, TextColumn, TimeRemainingColumn
from rich.prompt import Prompt
from rich.table import Table

from .cache import SearchCache
from .config import ConfigError, load_config
from .converter import ConversionRun, get_state
from .matching import DEFAULT_CONFIDENCE_THRESHOLD, ScoredCandidate, rank_candidates
from .models import SourceTrack
from .report import match_rate, needs_review, summarize, write_csv_report, write_json_report
from .spotify_target import SpotifyTarget
from .state import RunState
from .youtube_data_api_source import YouTubeDataApiSource
from .youtube_source import PlaylistNotFoundError, YouTubeMusicSource

SETUP_INSTRUCTIONS = """
Setup checklist
================

1. Create a Spotify app:
   https://developer.spotify.com/dashboard -> "Create app"
   - Add "http://127.0.0.1:8080/callback" as a Redirect URI (Settings).
   - Copy the Client ID and Client Secret.

2. Copy .env.example to .env in this directory and fill in:
     SPOTIFY_CLIENT_ID=...
     SPOTIFY_CLIENT_SECRET=...
     SPOTIFY_REDIRECT_URI=http://127.0.0.1:8080/callback

3. That's it for PUBLIC YouTube Music playlists -- no YouTube credentials
   needed. For a PRIVATE playlist, generate a ytmusicapi auth file:
     pip install ytmusicapi
     ytmusicapi oauth
   and point YTMUSIC_AUTH_FILE (or --yt-auth-file) at the resulting file.

   Tip: pass "LM" as the playlist instead of a URL to convert your YouTube
   Music "Liked Music" library (requires an auth file).

   If your network blocks music.youtube.com (some corporate/sandboxed
   networks do, while still allowing the official googleapis.com API):
   pass --source youtube-api with a free API key from
   https://console.cloud.google.com/apis/credentials (enable "YouTube
   Data API v3"), either via --youtube-api-key or the YOUTUBE_API_KEY
   env var. Matching accuracy is a bit lower with this source since
   regular YouTube playlists don't carry YT Music's structured artist
   metadata.

4. Run a conversion:
     python -m playlist_converter convert "<playlist URL or ID>" \\
         --name "My Converted Playlist" --dry-run

   Drop --dry-run once you're happy with the match report.
"""


def _configure_logging(verbose: bool, log_file: Path | None) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stderr)]
    if log_file:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.FileHandler(log_file))
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)-8s %(message)s",
        datefmt="%H:%M:%S",
        handlers=handlers,
        force=True,
    )
    # Quiet down noisy third-party loggers unless -v is passed.
    if not verbose:
        logging.getLogger("spotipy").setLevel(logging.WARNING)
        logging.getLogger("urllib3").setLevel(logging.WARNING)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="playlist-converter",
        description="Convert a YouTube Music playlist into a Spotify playlist.",
    )
    parser.add_argument("--env-file", help="Path to a .env file with credentials")
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose logging")
    parser.add_argument("--log-file", help="Override the default log file location")

    sub = parser.add_subparsers(dest="command", required=True)

    setup_p = sub.add_parser("setup", help="Show setup instructions")
    setup_p.set_defaults(func=cmd_setup)

    convert_p = sub.add_parser("convert", help="Convert a playlist")
    convert_p.add_argument("playlist", help="YouTube Music playlist URL or ID")
    convert_p.add_argument(
        "--name", help="Name for the Spotify playlist (default: source playlist title)"
    )
    convert_p.add_argument(
        "--public", action="store_true", help="Make the created playlist public"
    )
    convert_p.add_argument(
        "--dry-run",
        action="store_true",
        help="Match tracks and print a report without touching Spotify",
    )
    convert_p.add_argument(
        "--interactive",
        action="store_true",
        help="Prompt for a decision on each low-confidence match",
    )
    convert_p.add_argument(
        "--threshold",
        type=float,
        default=DEFAULT_CONFIDENCE_THRESHOLD,
        help=f"Auto-accept confidence threshold, 0-100 (default: {DEFAULT_CONFIDENCE_THRESHOLD})",
    )
    convert_p.add_argument(
        "--resume", action="store_true", help="Resume a previously interrupted run"
    )
    convert_p.add_argument(
        "--no-cache", action="store_true", help="Disable the on-disk search cache"
    )
    convert_p.add_argument(
        "--no-skip-duplicates",
        action="store_true",
        help="Allow adding tracks already present in the destination playlist",
    )
    convert_p.add_argument("--yt-auth-file", help="ytmusicapi auth file for private playlists")
    convert_p.add_argument(
        "--source",
        choices=["ytmusic", "youtube-api"],
        default="ytmusic",
        help="Which backend to read the source playlist from. 'ytmusic' "
        "(default) needs no credentials for public playlists but requires "
        "network access to music.youtube.com. 'youtube-api' uses the "
        "official, key-based YouTube Data API v3 instead -- a fallback for "
        "networks that block music.youtube.com specifically.",
    )
    convert_p.add_argument(
        "--youtube-api-key",
        help="API key for --source youtube-api (or set YOUTUBE_API_KEY)",
    )
    convert_p.add_argument(
        "--report-dir",
        default="./playlist-converter-reports",
        help="Directory to write CSV/JSON match reports to",
    )
    convert_p.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Only process the first N tracks (useful for a quick test run)",
    )
    convert_p.add_argument(
        "--strict",
        action="store_true",
        help="Exit with a non-zero status if any track was not matched "
        "(useful when scripting/automating conversions)",
    )
    convert_p.set_defaults(func=cmd_convert)

    return parser


def cmd_setup(args: argparse.Namespace) -> int:
    print(SETUP_INSTRUCTIONS)
    return 0


def _make_interactive_resolver(console, target: SpotifyTarget):
    def resolver(source: SourceTrack, ranked: list[ScoredCandidate]):
        while True:
            console.print(
                f"\n[bold yellow]Low-confidence match[/bold yellow] for: {source.display}"
            )
            for idx, sc in enumerate(ranked[:5], start=1):
                console.print(
                    f"  [{idx}] {sc.candidate.artist_display} - {sc.candidate.title} "
                    f"(score {sc.score:.0f})"
                )
            console.print("  [0] Skip this track")
            console.print("  [s] Search Spotify with different text")
            choices = [str(i) for i in range(0, len(ranked[:5]) + 1)] + ["s"]
            choice = Prompt.ask("Choose a match", choices=choices, default="0")

            if choice == "0":
                return None
            if choice == "s":
                query = Prompt.ask("Search query")
                custom_candidates = target.search_raw_query(query)
                ranked = rank_candidates(source, custom_candidates)
                if not ranked:
                    console.print("[red]No results for that search.[/red]")
                    return None
                continue
            return ranked[int(choice) - 1]

    return resolver


def cmd_convert(args: argparse.Namespace) -> int:
    console = Console()

    try:
        config = load_config(args.env_file)
    except ConfigError as exc:
        console.print(f"[bold red]Configuration error:[/bold red] {exc}")
        return 1

    log_file = Path(args.log_file) if args.log_file else config.state_dir / "playlist_converter.log"
    _configure_logging(args.verbose, log_file)
    logger = logging.getLogger("playlist_converter")

    try:
        return _run_convert(args, config, console)
    except KeyboardInterrupt:
        console.print(
            "\n[yellow]Interrupted.[/yellow] Progress has been saved -- "
            "re-run with [bold]--resume[/bold] to continue where you left off."
        )
        return 130
    except PlaylistNotFoundError as exc:
        console.print(f"[bold red]Error:[/bold red] {exc}")
        return 1
    except ConfigError as exc:
        console.print(f"[bold red]Configuration error:[/bold red] {exc}")
        return 1
    except Exception as exc:  # noqa: BLE001 - top-level safety net for a CLI tool
        logger.exception("Unhandled error during conversion")
        console.print(f"[bold red]Unexpected error:[/bold red] {exc}")
        console.print(
            f"See [bold]{log_file}[/bold] for details. "
            "If a Spotify playlist or partial matches were already created, "
            "re-run with [bold]--resume[/bold] to continue."
        )
        return 1


def _build_source(args: argparse.Namespace, config):
    if args.source == "youtube-api":
        api_key = args.youtube_api_key or config.youtube_api_key
        if not api_key:
            raise ConfigError(
                "--source youtube-api requires an API key: pass "
                "--youtube-api-key or set YOUTUBE_API_KEY."
            )
        return YouTubeDataApiSource(api_key=api_key)

    yt_auth = args.yt_auth_file or config.ytmusic_auth_file
    return YouTubeMusicSource(auth_file=yt_auth)


def _run_convert(args: argparse.Namespace, config, console) -> int:
    source = _build_source(args, config)

    console.print(f"[bold]Fetching YouTube playlist (source: {args.source})...[/bold]")
    fetched = source.fetch_playlist(args.playlist)
    tracks = fetched.tracks
    if args.limit is not None:
        tracks = tracks[: args.limit]

    if not tracks:
        console.print("[yellow]Playlist has no available tracks -- nothing to do.[/yellow]")
        return 0

    console.print(f"Found [bold]{len(tracks)}[/bold] tracks in '{fetched.title}'.")
    if fetched.unavailable_count:
        console.print(
            f"[yellow]{fetched.unavailable_count} track(s) in the source playlist are "
            "unavailable (removed/region-locked) and were skipped.[/yellow]"
        )

    dest_name = args.name or fetched.title
    cache = None if args.no_cache else SearchCache(config.cache_path)

    console.print("[bold]Authenticating with Spotify...[/bold]")
    target = SpotifyTarget(
        config.spotify,
        cache=cache,
        token_cache_path=config.state_dir / "spotify_token_cache.json",
    )

    run = ConversionRun(target=target, state_dir=config.state_dir, threshold=args.threshold)
    if args.resume:
        run_state, state_path = get_state(config.state_dir, args.playlist, dest_name)
    else:
        _, state_path = get_state(config.state_dir, args.playlist, dest_name)
        run_state = RunState(playlist_id=args.playlist)

    interactive_resolver = (
        _make_interactive_resolver(console, target) if args.interactive else None
    )

    progress = Progress(
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TextColumn("{task.completed}/{task.total}"),
        TimeRemainingColumn(),
        console=console,
    )
    with progress:
        task_id = progress.add_task("Matching tracks", total=len(tracks))

        def on_progress(i: int, total: int, result) -> None:
            progress.update(task_id, completed=i)

        results = run.match_tracks(
            tracks,
            run_state,
            interactive_resolver=interactive_resolver,
            progress_cb=on_progress,
            state_path=state_path,
        )

    counts = summarize(results)
    table = Table(title="Match summary")
    table.add_column("Status")
    table.add_column("Count", justify="right")
    for status, count in counts.items():
        if count:
            table.add_row(status, str(count))
    console.print(table)
    console.print(f"Match rate: [bold]{match_rate(results)}%[/bold]")

    report_dir = Path(args.report_dir)
    csv_path = report_dir / "match_report.csv"
    json_path = report_dir / "match_report.json"
    write_csv_report(results, csv_path)
    write_json_report(results, json_path)
    console.print(f"Full report written to [bold]{csv_path}[/bold] and [bold]{json_path}[/bold]")

    review = needs_review(results)
    if review:
        console.print(
            f"[yellow]{len(review)} track(s) need manual review[/yellow] "
            f"(see the report, or re-run with --interactive)."
        )

    if args.dry_run:
        console.print("[cyan]Dry run: no changes were made to Spotify.[/cyan]")
        return 2 if (args.strict and review) else 0

    console.print(f"[bold]Adding matched tracks to '{dest_name}' on Spotify...[/bold]")
    playlist_id, added = run.apply_to_spotify(
        results,
        playlist_name=dest_name,
        description=f"Converted from YouTube Music playlist '{fetched.title}' "
        "via playlist-converter.",
        public=args.public,
        run_state=run_state,
        state_path=state_path,
        skip_duplicates=not args.no_skip_duplicates,
    )
    console.print(
        f"[bold green]Done![/bold green] Added {added} track(s) to Spotify playlist "
        f"'{dest_name}' (id: {playlist_id})."
    )
    return 2 if (args.strict and review) else 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
