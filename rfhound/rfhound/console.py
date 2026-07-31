"""Console output helpers.

Uses `rich` when available for colour, tables and panels, and degrades to plain
`print` when it is not installed so RFHound always runs.
"""

from __future__ import annotations

from typing import Any, Iterable, Sequence

try:  # pragma: no cover - exercised implicitly
    from rich.console import Console as _RichConsole
    from rich.panel import Panel
    from rich.table import Table
    from rich.prompt import Prompt, Confirm

    _HAVE_RICH = True
    _console = _RichConsole()
except Exception:  # pragma: no cover - fallback path
    _HAVE_RICH = False
    _console = None


# ANSI colours for the fallback path.
_ANSI = {
    "red": "\033[31m",
    "green": "\033[32m",
    "yellow": "\033[33m",
    "blue": "\033[34m",
    "magenta": "\033[35m",
    "cyan": "\033[36m",
    "bold": "\033[1m",
    "dim": "\033[2m",
    "reset": "\033[0m",
}


def have_rich() -> bool:
    return _HAVE_RICH


def _plain(msg: str, colour: str | None = None) -> None:
    if colour and colour in _ANSI:
        print(f"{_ANSI[colour]}{msg}{_ANSI['reset']}")
    else:
        print(msg)


def print_(msg: str = "", style: str | None = None) -> None:
    if _HAVE_RICH:
        _console.print(msg, style=style)
    else:
        _plain(msg)


def info(msg: str) -> None:
    if _HAVE_RICH:
        _console.print(f"[cyan]›[/cyan] {msg}")
    else:
        _plain(f"> {msg}", "cyan")


def success(msg: str) -> None:
    if _HAVE_RICH:
        _console.print(f"[green]✓[/green] {msg}")
    else:
        _plain(f"[OK] {msg}", "green")


def warn(msg: str) -> None:
    if _HAVE_RICH:
        _console.print(f"[yellow]![/yellow] {msg}")
    else:
        _plain(f"[!] {msg}", "yellow")


def error(msg: str) -> None:
    if _HAVE_RICH:
        _console.print(f"[red]✗[/red] {msg}")
    else:
        _plain(f"[X] {msg}", "red")


def rule(title: str = "") -> None:
    if _HAVE_RICH:
        _console.rule(title)
    else:
        line = "-" * 60
        if title:
            print(f"\n{line}\n {title}\n{line}")
        else:
            print(line)


def panel(body: str, title: str = "", style: str = "cyan") -> None:
    if _HAVE_RICH:
        _console.print(Panel(body, title=title, border_style=style))
    else:
        rule(title)
        print(body)
        rule()


def table(title: str, columns: Sequence[str], rows: Iterable[Sequence[Any]]) -> None:
    """Render a simple table."""
    rows = [tuple(str(c) for c in r) for r in rows]
    if _HAVE_RICH:
        t = Table(title=title or None, header_style="bold cyan")
        for col in columns:
            t.add_column(str(col))
        for row in rows:
            t.add_row(*row)
        _console.print(t)
        return

    # Plain fallback: compute column widths.
    widths = [len(str(c)) for c in columns]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    if title:
        print(f"\n{title}")
    header = "  ".join(str(c).ljust(widths[i]) for i, c in enumerate(columns))
    print(header)
    print("  ".join("-" * widths[i] for i in range(len(columns))))
    for row in rows:
        print("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)))


def ask(prompt: str, default: str | None = None, choices: list[str] | None = None) -> str:
    if _HAVE_RICH:
        return Prompt.ask(prompt, default=default, choices=choices)
    suffix = f" [{default}]" if default is not None else ""
    if choices:
        suffix = f" ({'/'.join(choices)})" + suffix
    resp = input(f"{prompt}{suffix}: ").strip()
    return resp or (default or "")


def confirm(prompt: str, default: bool = False) -> bool:
    if _HAVE_RICH:
        return Confirm.ask(prompt, default=default)
    d = "Y/n" if default else "y/N"
    resp = input(f"{prompt} ({d}): ").strip().lower()
    if not resp:
        return default
    return resp in ("y", "yes")


BANNER = r"""
  ____  _____ _   _                       _
 |  _ \|  ___| | | | ___  _   _ _ __   __| |
 | |_) | |_  | |_| |/ _ \| | | | '_ \ / _` |
 |  _ <|  _| |  _  | (_) | |_| | | | | (_| |
 |_| \_\_|   |_| |_|\___/ \__,_|_| |_|\__,_|
   HackRF reconnaissance & pentesting toolkit
"""


def banner(version: str) -> None:
    if _HAVE_RICH:
        _console.print(f"[bold cyan]{BANNER}[/bold cyan]")
        _console.print(f"[dim]  v{version} · receive-first · transmit gated · no jamming[/dim]\n")
    else:
        print(BANNER)
        print(f"  v{version} - receive-first - transmit gated - no jamming\n")
