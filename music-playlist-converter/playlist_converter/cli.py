"""Command-line interface."""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from .cache import SearchCache
from .config import ConfigError, load_config
from .converter import ConversionRun, get_state
from .matching import DEFAULT_CONFIDENCE_THRESHOLD, ScoredCandidate
from .models import MatchStatus, SourceTrack
from .report import needs_review, summarize, write_csv_report, write_json_report
from .spotify_target import SpotifyTarget
from .state import save_state
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
        "--report-dir",
        default="./playlist-converter-reports",
        help="Directory to write CSV/JSON match reports to",
    )
    convert_p.set_defaults(func=cmd_convert)

    return parser


def cmd_setup(args: argparse.Namespace) -> int:
    print(SETUP_INSTRUCTIONS)
    return 0


def _make_interactive_resolver(console):
    from rich.prompt import IntPrompt

    def resolver(source: SourceTrack, ranked: list[ScoredCandidate]):
        console.print(f"\n[bold yellow]Low-confidence match[/bold yellow] for: {source.display}")
        for idx, sc in enumerate(ranked[:5], start=1):
            console.print(
                f"  [{idx}] {sc.candidate.artist_display} - {sc.candidate.title} "
                f"(score {sc.score:.0f})"
            )
        console.print("  [0] Skip this track")
        choice = IntPrompt.ask(
            "Choose a match", choices=[str(i) for i in range(0, len(ranked[:5]) + 1)], default=0
        )
        if choice == 0:
            return None
        return ranked[choice - 1]

    return resolver


def cmd_convert(args: argparse.Namespace) -> int:
    from rich.console import Console
    from rich.progress import BarColumn, Progress, TextColumn, TimeRemainingColumn
    from rich.table import Table

    console = Console()

    try:
        config = load_config(args.env_file)
    except ConfigError as exc:
        console.print(f"[bold red]Configuration error:[/bold red] {exc}")
        return 1

    log_file = config.state_dir / "playlist_converter.log"
    _configure_logging(args.verbose, log_file)

    yt_auth = args.yt_auth_file or config.ytmusic_auth_file
    source = YouTubeMusicSource(auth_file=yt_auth)

    console.print(f"[bold]Fetching YouTube Music playlist...[/bold]")
    try:
        playlist_title, tracks = source.fetch_playlist(args.playlist)
    except PlaylistNotFoundError as exc:
        console.print(f"[bold red]Error:[/bold red] {exc}")
        return 1

    if not tracks:
        console.print("[yellow]Playlist has no available tracks -- nothing to do.[/yellow]")
        return 0

    console.print(f"Found [bold]{len(tracks)}[/bold] tracks in '{playlist_title}'.")

    dest_name = args.name or playlist_title
    cache = None if args.no_cache else SearchCache(config.cache_path)

    console.print("[bold]Authenticating with Spotify...[/bold]")
    target = SpotifyTarget(config.spotify, cache=cache)

    run = ConversionRun(target=target, state_dir=config.state_dir, threshold=args.threshold)
    run_state, state_path = get_state(config.state_dir, args.playlist, dest_name)
    if not args.resume:
        from .state import RunState

        run_state = RunState(playlist_id=args.playlist)

    interactive_resolver = _make_interactive_resolver(console) if args.interactive else None

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
        )
        save_state(state_path, run_state)

    counts = summarize(results)
    table = Table(title="Match summary")
    table.add_column("Status")
    table.add_column("Count", justify="right")
    for status, count in counts.items():
        if count:
            table.add_row(status, str(count))
    console.print(table)

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
        return 0

    console.print(f"[bold]Adding matched tracks to '{dest_name}' on Spotify...[/bold]")
    playlist_id, added = run.apply_to_spotify(
        results,
        playlist_name=dest_name,
        description=f"Converted from YouTube Music playlist '{playlist_title}' "
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
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
