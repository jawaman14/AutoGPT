"""RFHound command-line interface.

Run ``rfhound`` with no arguments for the guided interactive menu, or use the
subcommands below for scripting. Everything is receive-first; transmit paths are
gated behind ``rfhound tx enable`` + an explicit ``--authorized`` flag.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import __version__, bandplan, console, device, proc, safety
from .config import Config, TxAllowRange, load_config, save_config, config_path
from .exceptions import RFHoundError
from .modules import capture as capture_mod
from .modules import decode as decode_mod
from .modules import recon as recon_mod
from .modules import replay as replay_mod
from .modules import report as report_mod
from .modules import sweep as sweep_mod


# --------------------------------------------------------------------------- #
# Subcommand handlers
# --------------------------------------------------------------------------- #
def cmd_doctor(args: argparse.Namespace, cfg: Config) -> int:
    console.rule("Environment check")
    # External tools.
    rows = []
    for tool, installed, path in proc.tool_status():
        rows.append([
            tool.name,
            "✓" if installed else "✗",
            tool.purpose,
            path or tool.install_hint,
        ])
    console.table("External tools", ["Tool", "OK", "Purpose", "Path / install hint"], rows)

    # Device.
    console.rule("HackRF device")
    try:
        info = device.get_info()
        console.success(f"HackRF detected (serial {info.serial}, fw {info.firmware})")
    except RFHoundError as exc:
        console.warn(str(exc).splitlines()[0])
        console.print_("  Tip: use --simulate on sweep/recon to try RFHound without hardware.")

    # rich?
    console.rule("RFHound")
    console.print_(f"Version: {__version__}")
    console.print_(f"Rich UI: {'yes' if console.have_rich() else 'no (plain text fallback)'}")
    console.print_(f"Config:  {config_path()} ({'exists' if config_path().exists() else 'defaults'})")
    console.print_(f"Output:  {cfg.output_dir}")
    console.print_(f"Transmit: {'ENABLED' if cfg.tx_enabled else 'disabled'}")
    return 0


def cmd_bands(args: argparse.Namespace, cfg: Config) -> int:
    bands = bandplan.BANDS
    if args.category:
        bands = [b for b in bands if b.category == args.category]
    if args.tag:
        bands = [b for b in bands if args.tag in b.tags]
    if args.search:
        q = args.search.lower()
        bands = [b for b in bands if q in b.name.lower() or q in b.description.lower()]
    if not bands:
        console.warn("No bands match that filter.")
        return 1
    rows = [
        [
            f"{b.low_hz/1e6:.3f}-{b.high_hz/1e6:.3f}",
            b.name,
            b.category,
            b.region,
            b.decoder or "-",
        ]
        for b in bands
    ]
    console.table(
        "Band plan (MHz)", ["Range", "Name", "Category", "Region", "Decoder"], rows
    )
    if args.verbose:
        for b in bands:
            console.rule(b.name)
            console.print_(b.description)
    return 0


def cmd_sweep(args: argparse.Namespace, cfg: Config) -> int:
    result = sweep_mod.sweep(
        cfg,
        args.start,
        args.stop,
        bin_khz=args.bin,
        snr_db=args.snr,
        sweeps=args.sweeps,
        simulate=args.simulate,
    )
    sweep_mod.render_spectrum(result)
    if result.peaks:
        rows = [
            [
                f"{p.freq_mhz:.4f}",
                f"{p.power_db}",
                p.band.name if p.band else "unknown",
                p.band.decoder if p.band and p.band.decoder else "-",
            ]
            for p in result.peaks[: args.top]
        ]
        console.table(
            f"Top {min(args.top, len(result.peaks))} peaks",
            ["Freq (MHz)", "Power (dB)", "Band", "Decoder"],
            rows,
        )
    else:
        console.warn("No peaks above the noise floor. Try lowering --snr or adding gain.")
    return 0


def cmd_recon(args: argparse.Namespace, cfg: Config) -> int:
    targets = None
    if args.category:
        targets = bandplan.bands_by_category(args.category)
        if not targets:
            console.error(f"No bands in category '{args.category}'.")
            return 1
    report = recon_mod.run_recon(
        cfg, targets=targets, snr_db=args.snr, bin_khz=args.bin, simulate=args.simulate
    )
    recon_mod.summarize(report)

    # Suggest next steps.
    suggestions = [
        f.band for f in report.active_findings if f.band.decoder
    ]
    if suggestions:
        console.rule("Suggested next steps")
        for b in suggestions[:8]:
            console.print_(
                f"  rfhound decode run {b.decoder} --freq {b.tune_hz/1e6:.3f}   "
                f"# {b.name}"
            )

    if args.report:
        out = Path(args.report)
        fmt = "html" if out.suffix.lower() in (".html", ".htm") else "md"
        report_mod.write_report(report, out, fmt=fmt)
        console.success(f"Report written to {out}")
    return 0


def cmd_capture(args: argparse.Namespace, cfg: Config) -> int:
    cap = capture_mod.capture_iq(
        cfg,
        args.freq,
        args.seconds,
        name=args.name,
        sample_rate=args.rate,
        note=args.note or "",
        simulate=args.simulate,
    )
    console.success(f"Captured {cap.seconds}s @ {cap.freq_hz/1e6:.3f} MHz")
    console.print_(f"  data: {cap.data_path}")
    console.print_(f"  meta: {cap.meta_path}")
    console.print_("  Open in URH / inspectrum / GNU Radio for analysis.")
    return 0


def cmd_decode(args: argparse.Namespace, cfg: Config) -> int:
    if args.decode_cmd == "list":
        rows = []
        for r in decode_mod.list_recipes():
            available, path = decode_mod.check_recipe(r)
            rows.append([
                r.id,
                r.name,
                r.category,
                f"{r.default_freq_hz/1e6:.3f}",
                "✓" if available else "✗ (missing)",
            ])
        console.table(
            "Decoder recipes", ["ID", "Name", "Category", "Def. MHz", "Tool ready"], rows
        )
        console.print_("\nRun one with:  rfhound decode run <id> [--freq MHz] [--seconds N]")
        return 0

    # run
    recipe = decode_mod.get_recipe(args.recipe)
    if not recipe:
        console.error(f"Unknown recipe '{args.recipe}'. Try: rfhound decode list")
        return 1
    freq_hz = int(args.freq * 1e6) if args.freq else recipe.default_freq_hz
    console.info(f"{recipe.name} @ {freq_hz/1e6:.3f} MHz for {args.seconds}s")
    if recipe.note:
        console.print_(f"  note: {recipe.note}")
    if args.dry_run:
        cmd = decode_mod.run_decoder(recipe, cfg, freq_hz=freq_hz, seconds=args.seconds, dry_run=True)
        console.print_(f"  would run: {cmd[0]}")
        return 0
    try:
        lines = decode_mod.run_decoder(
            recipe, cfg, freq_hz=freq_hz, seconds=args.seconds,
            on_line=console.print_,
        )
    except RFHoundError as exc:
        console.error(str(exc))
        return 1
    console.success(f"Decoder finished ({len(lines)} lines).")
    return 0


def cmd_replay(args: argparse.Namespace, cfg: Config) -> int:
    data_path = Path(args.file)
    try:
        plan = replay_mod.replay(
            cfg,
            data_path,
            authorized=args.authorized,
            freq_hz=int(args.freq * 1e6) if args.freq else None,
            tx_gain=args.gain,
            dry_run=args.dry_run,
        )
    except RFHoundError as exc:
        console.error(str(exc))
        return 2
    if args.dry_run:
        console.print_(f"  would run: {proc.format_command(plan.command)}")
    else:
        console.success(f"Replayed {data_path.name} @ {plan.freq_hz/1e6:.3f} MHz")
    return 0


def cmd_tx(args: argparse.Namespace, cfg: Config) -> int:
    if args.tx_cmd == "status":
        console.print_(f"Transmit: {'ENABLED' if cfg.tx_enabled else 'disabled'}")
        console.print_(f"Consent recorded: {cfg.tx_consent_at or '(none)'}")
        console.print_(f"Jurisdiction: {cfg.jurisdiction or '(unset)'}")
        if cfg.tx_allow_ranges:
            for r in cfg.tx_allow_ranges:
                console.print_(f"  allow: {r.low_hz/1e6:.3f}-{r.high_hz/1e6:.3f} MHz  {r.note}")
        else:
            console.print_("  allow: (no ranges declared)")
        return 0

    if args.tx_cmd == "disable":
        safety.disable_tx(cfg)
        console.success("Transmit disabled.")
        return 0

    # enable
    console.panel(safety.CONSENT_TEXT, title="Transmit legal terms", style="yellow")
    if not args.yes and not console.confirm("Do you accept these terms?", default=False):
        console.warn("Transmit not enabled.")
        return 1
    ranges = []
    for spec in args.allow or []:
        try:
            lo, hi = spec.split("-")
            ranges.append(TxAllowRange(int(float(lo) * 1e6), int(float(hi) * 1e6), "cli"))
        except ValueError:
            console.error(f"Bad --allow range '{spec}'. Use MHZ-MHZ, e.g. 433.0-434.8")
            return 1
    if not ranges:
        console.error("Provide at least one --allow MHZ-MHZ range you are authorized to use.")
        return 1
    try:
        safety.enable_tx(cfg, ranges, jurisdiction=args.jurisdiction or "")
    except RFHoundError as exc:
        console.error(str(exc))
        return 1
    console.success("Transmit enabled with the declared allow-list.")
    console.print_("Replay still requires an explicit --authorized flag per invocation.")
    return 0


def cmd_config(args: argparse.Namespace, cfg: Config) -> int:
    if args.config_cmd == "path":
        console.print_(str(config_path()))
        return 0
    if args.config_cmd == "init":
        path = save_config(cfg)
        console.success(f"Wrote default config to {path}")
        return 0
    # show
    import json
    console.print_(json.dumps(cfg.to_dict(), indent=2))
    return 0


def cmd_menu(args: argparse.Namespace, cfg: Config) -> int:
    from .menu import run_menu
    return run_menu(cfg)


# --------------------------------------------------------------------------- #
# Parser
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="rfhound",
        description="HackRF reconnaissance & pentesting toolkit (receive-first).",
    )
    p.add_argument("--version", action="version", version=f"rfhound {__version__}")
    sub = p.add_subparsers(dest="command")

    sub.add_parser("doctor", help="Check tools, HackRF device and config").set_defaults(func=cmd_doctor)
    sub.add_parser("menu", help="Launch the guided interactive menu").set_defaults(func=cmd_menu)

    pb = sub.add_parser("bands", help="Browse the frequency knowledge base")
    pb.add_argument("--category", help="Filter by category (ism, aviation, ...)")
    pb.add_argument("--tag", help="Filter by tag (tpms, keyfob, adsb, ...)")
    pb.add_argument("--search", help="Substring search of name/description")
    pb.add_argument("-v", "--verbose", action="store_true", help="Show descriptions")
    pb.set_defaults(func=cmd_bands)

    ps = sub.add_parser("sweep", help="Wideband spectrum sweep")
    ps.add_argument("start", type=float, help="Start frequency (MHz)")
    ps.add_argument("stop", type=float, help="Stop frequency (MHz)")
    ps.add_argument("--bin", type=int, default=100, help="Bin width (kHz)")
    ps.add_argument("--snr", type=float, default=12.0, help="Peak threshold above floor (dB)")
    ps.add_argument("--sweeps", type=int, default=1, help="Number of peak-held passes")
    ps.add_argument("--top", type=int, default=15, help="Show top-N peaks")
    ps.add_argument("--simulate", action="store_true", help="Synthesise data (no hardware)")
    ps.set_defaults(func=cmd_sweep)

    pr = sub.add_parser("recon", help="Auto-survey the high-value bands")
    pr.add_argument("--category", help="Restrict to one band category")
    pr.add_argument("--snr", type=float, default=12.0, help="Peak threshold (dB)")
    pr.add_argument("--bin", type=int, default=100, help="Bin width (kHz)")
    pr.add_argument("--report", help="Write a report to this path (.md or .html)")
    pr.add_argument("--simulate", action="store_true", help="Synthesise data (no hardware)")
    pr.set_defaults(func=cmd_recon)

    pc = sub.add_parser("capture", help="Record IQ to disk (with SigMF metadata)")
    pc.add_argument("freq", type=float, help="Center frequency (MHz)")
    pc.add_argument("seconds", type=float, help="Duration (s)")
    pc.add_argument("--name", help="Base filename")
    pc.add_argument("--rate", type=int, help="Sample rate (Hz)")
    pc.add_argument("--note", help="Free-text note stored in metadata")
    pc.add_argument("--simulate", action="store_true", help="Write placeholder (no hardware)")
    pc.set_defaults(func=cmd_capture)

    pd = sub.add_parser("decode", help="Protocol decoders (rtl_433, ADS-B, pagers, AIS...)")
    dsub = pd.add_subparsers(dest="decode_cmd", required=True)
    dsub.add_parser("list", help="List decoder recipes")
    drun = dsub.add_parser("run", help="Run a decoder recipe")
    drun.add_argument("recipe", help="Recipe id (see 'decode list')")
    drun.add_argument("--freq", type=float, help="Override frequency (MHz)")
    drun.add_argument("--seconds", type=float, default=30, help="Listen duration (s)")
    drun.add_argument("--dry-run", action="store_true", help="Print the command only")
    pd.set_defaults(func=cmd_decode)

    prp = sub.add_parser("replay", help="Replay a captured IQ file (GATED, authorized only)")
    prp.add_argument("file", help="Path to a .sigmf-data / .iq capture")
    prp.add_argument("--freq", type=float, help="Override frequency (MHz)")
    prp.add_argument("--gain", type=int, help="TX VGA gain (0-47 dB)")
    prp.add_argument("--authorized", action="store_true",
                     help="Assert you are authorized to transmit this signal")
    prp.add_argument("--dry-run", action="store_true", help="Show command, do not transmit")
    prp.set_defaults(func=cmd_replay)

    pt = sub.add_parser("tx", help="Manage transmit authorization")
    tsub = pt.add_subparsers(dest="tx_cmd", required=True)
    tsub.add_parser("status", help="Show transmit settings")
    tsub.add_parser("disable", help="Disable transmit")
    te = tsub.add_parser("enable", help="Enable transmit with a frequency allow-list")
    te.add_argument("--allow", action="append", metavar="MHZ-MHZ",
                    help="Allowed TX range (repeatable), e.g. --allow 433.0-434.8")
    te.add_argument("--jurisdiction", help="Your jurisdiction (for reports)")
    te.add_argument("--yes", action="store_true", help="Accept legal terms non-interactively")
    pt.set_defaults(func=cmd_tx)

    pcfg = sub.add_parser("config", help="Show / init configuration")
    csub = pcfg.add_subparsers(dest="config_cmd")
    csub.add_parser("show", help="Print current config")
    csub.add_parser("init", help="Write a default config file")
    csub.add_parser("path", help="Print config file path")
    pcfg.set_defaults(func=cmd_config, config_cmd="show")

    return p


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    parser = build_parser()
    args = parser.parse_args(argv)

    cfg = load_config()

    if not getattr(args, "command", None):
        # No subcommand -> friendly interactive menu.
        console.banner(__version__)
        from .menu import run_menu
        return run_menu(cfg)

    try:
        return args.func(args, cfg)
    except RFHoundError as exc:
        console.error(str(exc))
        return 2
    except KeyboardInterrupt:
        console.warn("Interrupted.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
