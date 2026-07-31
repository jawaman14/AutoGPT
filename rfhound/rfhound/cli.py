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
from .modules import defense as defense_mod
from .modules import intel as intel_mod
from . import plugins
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


def _load_json_list(path: str | None) -> list:
    if not path:
        raise RFHoundError("Provide --file <messages.json> (a JSON array) or use --simulate.")
    import json
    data = json.loads(Path(path).read_text())
    if not isinstance(data, list):
        raise RFHoundError(f"{path} must contain a JSON array of message objects.")
    return data


def cmd_mods(args: argparse.Namespace, cfg: Config) -> int:
    if args.mods_cmd == "sample":
        path = plugins.write_sample_mod()
        console.success(f"Wrote a sample mod to {path}")
        console.print_("Edit it, then run 'rfhound mods list' to load it.")
        return 0
    # list (also the default): load and report
    directory = Path(args.dir) if args.dir else plugins.mods_dir()
    loaded = plugins.load_mods(directory)
    console.print_(f"Mods directory: {directory}")
    if not loaded:
        console.warn("No mods found. Create one with 'rfhound mods sample'.")
        return 0
    rows = []
    for m in loaded:
        status = "ok" if not m.error else f"ERROR: {m.error}"
        rows.append([m.name, m.version,
                     f"{len(m.bands)}b/{len(m.recipes)}r/{len(m.detectors)}d", status])
    console.table("Loaded mods", ["Name", "Version", "Adds", "Status"], rows)
    return 0


def cmd_defense(args: argparse.Namespace, cfg: Config) -> int:
    if args.defense_cmd == "monitor":
        report = defense_mod.monitor_interference(
            cfg, args.start, args.stop,
            iterations=args.samples, interval_s=args.interval,
            threshold_db=args.threshold, simulate=args.simulate,
        )
        defense_mod.print_interference(report)
        return 1 if report.jammed else 0

    if args.defense_cmd == "rolling-assess":
        if args.simulate:
            payloads = defense_mod.simulate_payloads(args.kind)
        elif args.file:
            payloads = Path(args.file).read_text().splitlines()
        else:
            console.error("Provide --file <payloads.txt> (one code per line) or --simulate.")
            return 1
        assessment = defense_mod.assess_rolling_code(payloads)
        defense_mod.print_rolling(assessment)
        return 0

    if args.defense_cmd == "replay-check":
        # Observations file: 'timestamp payload' per line, or --simulate.
        if args.simulate:
            t0 = 1000.0
            obs = [  # same fixed code re-sent 3x in <1s => replay signature
                defense_mod.Observation(t0, "10101100"),
                defense_mod.Observation(t0 + 0.4, "10101100"),
                defense_mod.Observation(t0 + 0.7, "10101100"),
            ]
        elif args.file:
            obs = []
            for line in Path(args.file).read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) >= 2:
                    obs.append(defense_mod.Observation(float(parts[0]), parts[1]))
        else:
            console.error("Provide --file <observations.txt> ('ts payload' per line) or --simulate.")
            return 1
        findings = defense_mod.detect_replays(obs, rolling_expected=not args.fixed)
        if not findings:
            console.success("No replay signatures detected.")
            return 0
        console.error(f"Possible replay attack(s) detected: {len(findings)}")
        for f in findings:
            console.print_(f"  • payload {f.payload}: seen {f.count}x, "
                           f"min gap {f.min_gap_s}s — {f.reason}")
        return 1

    if args.defense_cmd == "baseline":
        if args.baseline_cmd == "save":
            path = intel_mod.save_baseline(
                cfg, args.start, args.stop, Path(args.out), simulate=args.simulate
            )
            console.success(f"Baseline saved to {path}")
            return 0
        # diff
        findings = intel_mod.diff_baseline(
            cfg, Path(args.file), new_threshold_db=args.threshold, simulate=args.simulate
        )
        if not findings:
            console.success("No new or elevated emitters vs baseline — area clean.")
            return 0
        console.error(f"TSCM: {len(findings)} new/elevated emitter(s) vs baseline:")
        rows = [
            [f"{f.freq_mhz:.4f}", f"{f.power_db}", f.kind,
             f"+{f.delta_db}" if f.baseline_db is not None else "new",
             f.band or "unknown"]
            for f in findings
        ]
        console.table("Rogue emitters", ["Freq (MHz)", "Power dB", "Kind", "Δ dB", "Band"], rows)
        return 1

    if args.defense_cmd == "spoof-check":
        if args.protocol == "adsb":
            msgs = intel_mod.simulate_adsb_messages() if args.simulate else _load_json_list(args.file)
            findings = intel_mod.detect_adsb_spoofing(msgs)
        else:
            msgs = intel_mod.simulate_ais_messages() if args.simulate else _load_json_list(args.file)
            findings = intel_mod.detect_ais_spoofing(msgs)
        if not findings:
            console.success(f"No {args.protocol.upper()} spoofing indicators found.")
            return 0
        console.error(f"{args.protocol.upper()} spoofing indicators: {len(findings)}")
        for f in findings:
            console.print_(f"  • [{f.severity}] {f.entity_id} — {f.kind}: {f.detail}")
        return 1

    if args.defense_cmd == "drone-scan":
        hits = intel_mod.drone_scan(cfg, simulate=args.simulate)
        if not hits:
            console.success("No drone-band activity detected.")
            return 0
        console.error(f"Counter-UAS: activity in {len(hits)} drone-band bin(s):")
        rows = [[h.band, f"{h.freq_mhz:.3f}", f"{h.power_db}", h.confidence] for h in hits]
        console.table("Drone-band detections", ["Band", "Freq (MHz)", "Power dB", "Confidence"], rows)
        return 1

    if args.defense_cmd == "resilience":
        payloads = None
        if args.payloads:
            payloads = Path(args.payloads).read_text().splitlines()
        result = defense_mod.run_resilience_test(
            cfg,
            device=args.device or "device-under-test",
            payloads=payloads,
            replayed=args.replayed,
            device_actuated=(None if args.actuated is None else args.actuated),
            simulate=args.simulate,
        )
        defense_mod.print_resilience(result)
        return 0

    console.error("Unknown defense subcommand.")
    return 1


def cmd_web(args: argparse.Namespace, cfg: Config) -> int:
    from .web import server as web_server
    force_sim = args.simulate or not device.is_present()
    if force_sim and not args.simulate:
        console.warn("No HackRF detected — dashboard will run in SIMULATE mode.")
    url = f"http://{args.host}:{args.port}"
    if args.open:
        import webbrowser
        webbrowser.open(url)
    web_server.serve(cfg, host=args.host, port=args.port, force_simulate=force_sim)
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

    pw = sub.add_parser("web", help="Launch the browser dashboard + REST API")
    pw.add_argument("--host", default="127.0.0.1", help="Bind address (default localhost)")
    pw.add_argument("--port", type=int, default=8000, help="Port (default 8000)")
    pw.add_argument("--simulate", action="store_true", help="Force simulate mode")
    pw.add_argument("--open", action="store_true", help="Open a browser window")
    pw.set_defaults(func=cmd_web)

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

    pdf = sub.add_parser("defense", help="Defensive analysis: detect attacks, assess resilience")
    fsub = pdf.add_subparsers(dest="defense_cmd", required=True)

    fm = fsub.add_parser("monitor", help="Detect jamming / interference on a band")
    fm.add_argument("start", type=float, help="Start frequency (MHz)")
    fm.add_argument("stop", type=float, help="Stop frequency (MHz)")
    fm.add_argument("--samples", type=int, default=12, help="Number of sweeps to take")
    fm.add_argument("--interval", type=float, default=1.0, help="Seconds between sweeps")
    fm.add_argument("--threshold", type=float, default=10.0,
                    help="Noise-floor rise over baseline that triggers an alarm (dB)")
    fm.add_argument("--simulate", action="store_true", help="Synthesise a jamming event")

    fr = fsub.add_parser("rolling-assess", help="Assess a device's fixed/rolling-code posture")
    fr.add_argument("--file", help="Text file of captured payloads, one per line")
    fr.add_argument("--kind", default="fixed", choices=["fixed", "counter", "rolling"],
                    help="With --simulate, which synthetic device to model")
    fr.add_argument("--simulate", action="store_true", help="Use synthetic payloads")

    frc = fsub.add_parser("replay-check", help="Detect replay attacks in observed transmissions")
    frc.add_argument("--file", help="'timestamp payload' per line")
    frc.add_argument("--fixed", action="store_true",
                     help="Device uses a fixed code (only flag implausibly fast repeats)")
    frc.add_argument("--simulate", action="store_true", help="Use a synthetic replay trace")

    fbl = fsub.add_parser("baseline", help="TSCM: save a known-good spectrum and diff for rogue emitters")
    blsub = fbl.add_subparsers(dest="baseline_cmd", required=True)
    bsave = blsub.add_parser("save", help="Save a baseline sweep")
    bsave.add_argument("start", type=float, help="Start MHz")
    bsave.add_argument("stop", type=float, help="Stop MHz")
    bsave.add_argument("--out", required=True, help="Baseline output path (.json)")
    bsave.add_argument("--simulate", action="store_true")
    bdiff = blsub.add_parser("diff", help="Diff current spectrum against a saved baseline")
    bdiff.add_argument("file", help="Saved baseline .json")
    bdiff.add_argument("--threshold", type=float, default=10.0,
                       help="dB increase over baseline that flags an emitter")
    bdiff.add_argument("--simulate", action="store_true")

    fsc = fsub.add_parser("spoof-check", help="Detect ADS-B / AIS spoofing in decoded messages")
    fsc.add_argument("protocol", choices=["adsb", "ais"])
    fsc.add_argument("--file", help="JSON array of decoded messages")
    fsc.add_argument("--simulate", action="store_true", help="Use a synthetic spoofed stream")

    fds = fsub.add_parser("drone-scan", help="Counter-UAS: scan drone control/video bands")
    fds.add_argument("--simulate", action="store_true")

    fres = fsub.add_parser("resilience", help="Resilience-test YOUR OWN device and report")
    fres.add_argument("--device", help="Name/label of the device under test")
    fres.add_argument("--payloads", help="Text file of captured payloads (one per line)")
    fres.add_argument("--replayed", action="store_true",
                      help="You performed the gated replay (rfhound replay --authorized)")
    fres.add_argument("--actuated", type=lambda s: s.lower() in ("1", "true", "yes", "y"),
                      default=None, help="Did the device actuate on replay? true/false")
    fres.add_argument("--simulate", action="store_true", help="Run a synthetic resilience test")
    pdf.set_defaults(func=cmd_defense)

    pm = sub.add_parser("mods", help="Manage extension mods/plugins")
    msub = pm.add_subparsers(dest="mods_cmd")
    ml = msub.add_parser("list", help="Load and list mods")
    ml.add_argument("--dir", help="Mods directory (default ~/.config/rfhound/mods)")
    msub.add_parser("sample", help="Write a sample mod to the mods directory")
    pm.set_defaults(func=cmd_mods, mods_cmd="list", dir=None)

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
