# music-playlist-converter

Convert a YouTube Music playlist into a Spotify playlist, with fuzzy
matching, a resumable/cached run so re-runs are cheap, and a clear report of
anything that couldn't be matched automatically.

## Why not one of the existing converters?

There are several small scripts already out there (search "youtube spotify
playlist converter" on GitHub) that do the basic job: pull track titles from
YouTube, search Spotify, add whatever comes back first. In practice that
runs into a few recurring problems, which this project addresses directly:

| Problem with typical converters | What this does instead |
| --- | --- |
| Requires a Google Cloud project + YouTube Data API key just to read a playlist | Reads **public** YouTube Music playlists with zero YouTube credentials (via `ytmusicapi`); auth is only needed for private playlists |
| Exact/substring title matching misses anything with "(Official Video)", "feat.", remasters, etc. | Normalizes noisy titles and scores candidates on title + artist + duration similarity, picking the best match |
| Silently adds the first search result, even if it's wrong | Flags low-confidence matches instead of guessing; `--interactive` lets you resolve them on the spot |
| Re-running after a crash/rate-limit re-does everything from scratch | Caches Spotify search results and checkpoints progress to disk; `--resume` picks up where it left off |
| No visibility into what happened | Rich progress bar during the run, a summary table at the end, and a full CSV + JSON report of every track's outcome |
| Adds duplicate tracks if you run it twice | Checks the destination playlist's existing tracks and skips ones already there |
| Crashes on the first 429 | Retries with exponential backoff, honoring `Retry-After` when present |

## Setup

```bash
cd music-playlist-converter
pip install -r requirements.txt
python -m playlist_converter setup   # prints a step-by-step checklist
```

In short:

1. Create a Spotify app at https://developer.spotify.com/dashboard and add
   `http://127.0.0.1:8080/callback` as a Redirect URI.
2. `cp .env.example .env` and fill in `SPOTIFY_CLIENT_ID` /
   `SPOTIFY_CLIENT_SECRET`.
3. That's it for **public** YouTube Music playlists. For a **private**
   playlist, generate a `ytmusicapi` auth file (`ytmusicapi oauth`) and set
   `YTMUSIC_AUTH_FILE`, or pass `--yt-auth-file`.

### If your network blocks music.youtube.com

`ytmusicapi` talks to `music.youtube.com`'s unofficial internal API. Some
networks (corporate proxies, some sandboxes) block that consumer-facing
domain specifically while still allowing the officially documented
`googleapis.com` surface. For that case, pass `--source youtube-api` with a
free API key from
[console.cloud.google.com/apis/credentials](https://console.cloud.google.com/apis/credentials)
(enable "YouTube Data API v3"), either via `--youtube-api-key` or the
`YOUTUBE_API_KEY` env var:

```bash
python -m playlist_converter convert "<playlist URL or ID>" \
  --source youtube-api --youtube-api-key "$YOUTUBE_API_KEY" --dry-run
```

Trade-off: regular YouTube playlist metadata doesn't carry YT Music's
structured artist/album fields, so the artist is guessed heuristically from
the video title (`"Artist - Title"`) or channel name -- matching is usually
a bit less accurate than the default `ytmusic` source.

## Usage

Preview a conversion without touching Spotify:

```bash
python -m playlist_converter convert \
  "https://music.youtube.com/playlist?list=PL..." \
  --name "My Converted Playlist" \
  --dry-run
```

This prints a match summary and writes a detailed report to
`./playlist-converter-reports/match_report.csv` (and `.json`) so you can
review exactly what would be added before committing to it.

Once you're happy, drop `--dry-run` to actually create/update the Spotify
playlist:

```bash
python -m playlist_converter convert \
  "https://music.youtube.com/playlist?list=PL..." \
  --name "My Converted Playlist"
```

Useful flags:

- `--interactive` — for any track below the confidence threshold, shows the
  ranked candidates and lets you pick one, skip it, or type `s` to search
  Spotify with different text (e.g. if the YouTube title/artist is too
  mangled for a good automatic match) instead of guessing.
- `--resume` — continue a previous run using its saved state instead of
  starting over. Tracks that were already matched (or already added) aren't
  redone; anything that came back `not_found`/`low_confidence` is retried in
  case the catalog or your `--threshold`/`--interactive` choice changed.
  Progress is checkpointed after every track, so this is safe to use after a
  crash, rate limit, or Ctrl-C at any point in the run.
- `--threshold 80` — raise/lower the auto-accept confidence score (0-100,
  default 72). Higher means fewer wrong matches but more tracks flagged for
  review.
- `--limit 10` — only process the first N tracks; handy for a quick sanity
  check before converting a huge playlist.
- `--strict` — exit with status 2 if anything ended up unmatched (needing
  review), so a wrapping script/CI job can detect an incomplete conversion.
- `--public` — make the created Spotify playlist public (default: private).
- `--no-skip-duplicates` — allow adding a track even if it's already in the
  destination playlist.
- `--no-cache` — bypass the on-disk search cache for this run.
- `-v` / `--verbose` — verbose logging (also written to
  `~/.playlist-converter/playlist_converter.log`, or `--log-file <path>`).

Run `python -m playlist_converter convert --help` for the full list.

If something goes wrong mid-run (network blip, expired token, Ctrl-C), the
error is reported cleanly instead of a raw traceback, and any progress made
so far is already saved -- just re-run the same command with `--resume`.

## How matching works

Each YouTube Music track is normalized (stripping things like "(Official
Video)", "[Remaster]", "feat. X") and used to search Spotify. Every
candidate Spotify returns is scored on:

- **Title similarity** (55%) — fuzzy string match on the cleaned titles.
- **Artist similarity** (35%) — fuzzy match across all listed artists.
- **Duration proximity** (10%) — tracks within ~12 seconds score highest;
  wildly different durations (covers, remixes, extended edits) score low.

The highest-scoring candidate is auto-accepted if its score is at or above
`--threshold`. Otherwise the track is marked `low_confidence` in the report
(or handed to you interactively with `--interactive`), rather than silently
adding a possibly-wrong track.

## Where things are stored

- **Search cache**: `~/.playlist-converter/search_cache.sqlite3`
- **Run state** (for `--resume`): `~/.playlist-converter/state/`
- **Spotify auth token**: `~/.playlist-converter/state/spotify_token_cache.json`
  (so you only have to log in through the browser once, regardless of which
  directory you run the tool from)
- **Logs**: `~/.playlist-converter/playlist_converter.log`
- Override the base directory with the `PLAYLIST_CONVERTER_HOME` env var.

## Running tests

```bash
pip install -r requirements-dev.txt
pytest tests/
```
