"""Build docs/BALANCE.md from saved simulation results (sim-results/*.json)."""
from __future__ import annotations

import json
from pathlib import Path

# What the simulations changed, oldest first. Numbers are from the runs that
# motivated each change; the tables below are regenerated from current code.
CHANGELOG = [
    ("Pine Ridge was a trap",
     "Feasibility sweep: a C172 could land at PNR but only take off again with <25% fuel. The 22 m tree lines "
     "60 m past each runway end blocked any loaded climb-out.",
     "Tree lines moved to 110 m past the ends and cut to 16 m (the 50 ft obstacle a pilot's handbook plans for). "
     "A C172 now gets out at every load the sweep tries."),
    ("Old Quarry was a trap",
     "No aircraft could take off from QRY in either direction: a 13 m rim just past the downhill end, and the "
     "pit wall (215 m in 240 m) past the other.",
     "Added a graded haul road out of the downhill end (`Airfield.haul_road`). QRY becomes a one-way strip: land "
     "uphill, take off downhill. It stays the hardest strip on the island."),
    ("Narrow strips had no way to turn round",
     "A 180-degree pivot needs about 13 m, more than the width of QRY (12 m) or PNR (15 m). Backtracking for a "
     "downhill takeoff left you in the rough.",
     "New actions: differential toe-brakes for pivot turns (`Controls.diff_brake`), and 'push her round' "
     "(key I, 20 s solo or 10 s with crew), which is what bush pilots actually do."),
    ("Flying under the radar never worked",
     "Tactical sweep: low-level runs with the transponder off were flagged 100% and busted 78-100%. Squawking "
     "like legitimate traffic delivered 89% against light police. That is the opposite of the history, and it "
     "made one tactic dominant.",
     "A primary-only radar track now builds suspicion slowly (1.2-4.2 %/s instead of 8-33 %/s), so it takes "
     "30-60 s of sustained track. Behaviour multiplies it: low and fast inbound from the sea x2.5, orbiting low "
     "over water +3 %/s, a squawk that vanishes mid-track +50. The aerostat's 20 m floor is the counter to "
     "low flying."),
    ("Then hiding in plain sight became dominant",
     "With the radar fix in, squawking like legitimate traffic delivered 73-100% of loads and was never "
     "flagged by light or standard police. Only an informant's tip stopped it. The quarry sits in radar "
     "shadow, so nothing saw where the 'legitimate' flight went.",
     "Two linked rules. (1) A squawking track that drops off the scope low and heading for a shady strip is "
     "flagged at once ('nobody legit lands at Old Quarry'); a bush strip only earns +30 suspicion, because "
     "honest jobs go there too. (2) A hot load at a bush or shady strip takes 60 s to unload, and a police "
     "aircraft within 2 km in that time means a raid. The tell now has consequences: the task force races "
     "you to the strip, and a patrol parked nearby wins the race."),
    ("Coast Guard cutters never caught anything",
     "0% boat seizures across 189 flights: cutters sailed from Port Harbor, 20 km away at 32 kt, and the "
     "go-fast was gone in 5 minutes.",
     "A funded cutter starts the night on picket off the coast (`Maritime.new_cutter(at=...)`). Seizures "
     "appear (13-17% of sea runs in later sweeps) without making airdrops pointless."),
    ("The law won 81% of seasons",
     "First strategic run: the runner equilibrium win rate was 0.18. Retiring rich happened in 2% of "
     "seasons, bribery cut win rate by 18 points, and wiretaps added 43 points.",
     "Retire target $90k -> $60k; run payout $11k -> $13k; contract crews cheaper ($4k -> $3k) and better "
     "paid (50% -> 60% share); bribes cheaper; wiretap 7 -> 4 evidence/night (warrant at 20 evidence, $7k); "
     "audits worth more (3.5 -> 6 per exposure point, $5k -> $4k); seizure share 50% -> 80% (the 1984 "
     "equitable-sharing rule); encryption $8k -> $5k; new runner order 'gear' (scanner/detector) so "
     "encryption has something to counter; comeback gap 30% -> 25%. Equilibrium: 0.18 -> 0.30 -> 0.49 -> 0.50."),
    ("Calibrated to flown numbers, the law won 98%",
     "Once the season simulator used rates flown by the bot instead of hand estimates, the organisation's "
     "equilibrium win rate fell to 2% and 48% of seasons ended broke. Three causes: the aerostat's 40 km "
     "radius covered every route on the island; the abstract model treated five police units as five times "
     "one; and every bust fed the case against the boss, a snowball.",
     "Aerostat radius 40 -> 22 km (south coast and sea lanes; the northern mountains are the way round it). "
     "Interception now has diminishing returns (`k * ln(1 + units)`, with k fitted to flown flights). Units "
     "cost more (helicopter $3k -> $4k, interceptor $5k -> $7k, aerostat $4k -> $6k). A contract crew's bust "
     "gives 2 evidence and never flips, because they don't know who they fly for. Bust evidence 12 -> 6; "
     "wiretap 4 -> 3; bankruptcy at -$10k. A bribed dispatcher's warning now reroutes the run away from the "
     "patrol and the balloon. Economy: run value $15k, retire at $45k, start with $16k, police base budget "
     "$9k. A 16-point grid search picked the last four. The bot's low-level crash rate is capped at 6% in "
     "the calibration, because it overstates a competent human. A smarter organisation bot joined the pool so "
     "both sides have one strategy that uses all its information (principle P8: balance at equal skill). "
     "Equilibrium: 0.02 -> 0.09 -> 0.25 -> 0.37 -> 0.475."),
    ("The test rig itself was wrong once",
     "'aerostat' and 'standard' postures gave identical numbers because the Session raises the aerostat "
     "automatically whenever the feature is on.",
     "Fixed in the rig (the aerostat is available but only raised by the posture). Lesson: check that "
     "configurations which should differ actually do, before believing the numbers."),
    ("Recruiting an informant was the single best move in the game",
     "At 8000 seasons the equilibrium (organisation win 45.5%) looked fair, but the ablation table told a "
     "different story: removing 'recruit' alone swung it to 60% (+14.5, the biggest number on the board). "
     "Reading the code found why: an informant gave three stacked, always-on bonuses (a flat +45% detection "
     "chance on tip nights, a 1.2x intercept-hazard multiplier on top of that, and 2.5 evidence/night per "
     "head, up to 3 heads) for $3k plus $1k/night upkeep, and a whole computed 'informant_mult' field was "
     "dead code that never reached the resolver. Worse, 'cautious' - the equilibrium runner strategy - never "
     "called 'counterintel' at all, so the one built-in counter to informants was never used by the side that "
     "was actually winning.",
     "Informant cap 3 -> 2; recruiting cost $3k -> $5k; evidence/informant 2.5 -> 1.8; the tip's detection "
     "bonus +45% -> +30% and its intercept-match multiplier 1.2x -> 1.1x; counterintel cheaper ($5k -> $4k) "
     "and burns 75% of informants instead of 60%. Removed the dead 'informant_mult' field instead of wiring "
     "it in on top of the tip bonus, which would have doubled up the same effect. Gave 'runner_cautious' a "
     "counterintel response whenever it already reaches for opsec (serious evidence rumour or heat > 70), "
     "matching what 'adaptive' and 'smart' already did. Equilibrium: 0.455 -> 0.450 at 40000 seasons; the "
     "investigation trio (recruit/audit/wiretap) still swings the most on ablation (+15 to +20 points each), "
     "which tracks with evidence being the task force's only win condition, but it is now measured, not "
     "accidentally doubled by dead code."),
]


def _load(d: Path, name: str):
    p = d / f"{name}.json"
    return json.loads(p.read_text()) if p.exists() else None


def _pct(v) -> str:
    return "-" if v is None else f"{100 * v:.0f}%"


def write_report(results_dir: Path, out: Path) -> Path:
    from .feasibility import table as feas_table
    from .strategic import action_values, dominance, equilibrium, matrix, summary
    from .tactical import LAW_CONFIGS, MISSIONS, TACTICS, calibrate, rates

    lines = ["# Skyrunner balance report", "",
             "Generated by `python -m skyrunner.sim report` from the raw runs in `sim-results/`. The method and "
             "the reasoning behind the targets are in [MULTIPLAYER.md](MULTIPLAYER.md).", "",
             "**Targets.** Equilibrium win rate 50% ± 5 for same-skill play. No dominant strategy. At least two "
             "strategies per side in the equilibrium mix. Every win condition happens in at least 8% of seasons. "
             "Comebacks (the side leading at half-time loses) in 15-35% of seasons. No airfield you can land at "
             "but can't leave with the aircraft that got you there.", ""]

    lines += ["## What the simulations changed", ""]
    for i, (title, found, change) in enumerate(CHANGELOG, 1):
        lines += [f"{i}. **{title}.** *Found:* {found} *Changed:* {change}", ""]

    feas = _load(results_dir, "feasibility")
    if feas:
        ok = sum(r["ok"] for r in feas)
        lines += ["## 1. Can you get in and out? (feasibility)", "",
                  f"The pilot bot flew {len(feas)} takeoffs and landings: every aircraft × airfield × load "
                  f"(light = 30% fuel; half = 60% fuel + half payload; max = full fuel + payload to MTOW). "
                  f"{ok} succeeded. L = landing, T = takeoff.", "", feas_table(feas), "",
                  "How to read it: the C172 row is the one that matters for fairness, because every career "
                  "starts in one. It lands everywhere at light and half loads and takes off from everywhere "
                  "except the quarry at half load. At max weight it can't leave the plateau (EGL) or the "
                  "quarry. That is the trade-off the game is built on: tight strips mean light loads. The PA28, C182 and Twin Otter "
                  "rows mostly measure the bot rather than the aircraft. It was tuned on the C172 and C310, and "
                  "the PA28's JSBSim model needs about -0.6 elevator of trim at approach speed. Treat red cells "
                  "there as 'the bot can't', not 'a human can't'.", ""]

    tac = _load(results_dir, "tactical")
    if tac:
        lines += ["## 2. Cops vs smugglers, flown (tactical)", "",
                  f"{len(tac)} real flights: the pilot bot (C172) against the AI task force. Three missions "
                  f"({', '.join(f'{k}: {a}->{b}' for k, (a, b) in MISSIONS.items())}), "
                  f"{len(set(r['law'] for r in tac))} police postures, three runner tactics: *low* (50 m, "
                  "transponder off, valley routing), *high* (450 m, squawking like legitimate traffic) and "
                  "*evasive* (low plus scanner, detector and evasion).", "",
                  "| | n | flagged | intercepted | busted | crashed | delivered | boat seized |",
                  "|---|---|---|---|---|---|---|---|"]

        def row(label, **w):
            q = rates(tac, **w)
            if q.get("n"):
                lines.append(f"| {label} | {q['n']} | {_pct(q['flagged'])} | {_pct(q['intercepted'])} | "
                             f"{_pct(q['busted'])} | {_pct(q['crashed'])} | {_pct(q['delivered'])} | "
                             f"{_pct(q['boat_seized'])} |")
        row("**all**")
        for t in TACTICS:
            row(f"tactic: {t}", tactic=t)
        for law in LAW_CONFIGS:
            row(f"police: {law}", law=law)
        for z in MISSIONS:
            row(f"zone: {z}", zone=z)
        lines += ["", "Tactic × posture (delivered):", "", "| tactic | " + " | ".join(
            law for law in LAW_CONFIGS if rates(tac, law=law).get("n")) + " |",
            "|---|" + "---|" * len([law for law in LAW_CONFIGS if rates(tac, law=law).get("n")])]
        for t in TACTICS:
            cells = [_pct(rates(tac, tactic=t, law=law).get("delivered")) for law in LAW_CONFIGS
                     if rates(tac, law=law).get("n")]
            lines.append(f"| {t} | " + " | ".join(cells) + " |")
        cal = calibrate(tac)
        lines += ["", f"Calibration fed to the season simulator: `{cal}`", ""]

    strat = _load(results_dir, "strategic")
    if strat:
        R, L, m = matrix(strat)
        p, q, v = equilibrium(m)
        s = summary(strat)
        lines += ["## 3. Whole seasons, HQ vs HQ (strategic)", "",
                  f"{s['seasons']} simulated seasons, {len(R)} organisation strategies × {len(L)} task-force "
                  "strategies. Cells are the organisation's win rate.", "",
                  "| boss \\ chief | " + " | ".join(L) + " |", "|---|" + "---|" * len(L)]
        for i, r in enumerate(R):
            lines.append(f"| {r} | " + " | ".join(f"{100 * x:.0f}%" for x in m[i]) + " |")
        lines += ["", f"- **Equilibrium win rate (organisation): {100 * v:.1f}%** (target 50 ± 5)",
                  "- Equilibrium mix, organisation: " + ", ".join(f"{R[i]} {100 * x:.0f}%" for i, x in enumerate(p) if x > 0.01),
                  "- Equilibrium mix, task force: " + ", ".join(f"{L[i]} {100 * x:.0f}%" for i, x in enumerate(q) if x > 0.01),
                  f"- Raw win rate over all pairings: {_pct(s['runner_win'])} for the organisation",
                  f"- Average season length: {s['nights_mean']:.1f} nights; decided before the last night: {_pct(s['ended_early'])}",
                  f"- Comebacks (half-time leader loses): {_pct(s['comeback_rate'])}; close finishes: {_pct(s['close_finish'])}",
                  "", "How seasons end:", ""]
        lines += [f"- {k}: {_pct(x)}" for k, x in s["reasons"].items()]
        dom = dominance(m, R, L)
        lines += ["", "Dominance between archetypes (a bot archetype being beaten everywhere is fine; a *mechanic* "
                  "nobody should use is not, see the next table): " + ("; ".join(dom) if dom else "none"), ""]
        for side in ("runner", "law"):
            av = action_values(strat, side)
            if av:
                lines += [f"What each {('organisation' if side == 'runner' else 'task-force')} order is worth "
                          "(win rate when the random bot used it vs didn't):", "",
                          "| order | effect | uses |", "|---|---|---|"]
                lines += [f"| {a} | {d * 100:+.0f} pts | {n} |" for a, (d, n) in sorted(av.items(), key=lambda kv: -kv[1][0])]
                lines.append("")
    abl = _load(results_dir, "ablation")
    if abl:
        lines += ["Ablations: equilibrium win rate with one mechanic switched off (baseline "
                  f"{100 * abl['base']:.1f}%). Big swings mean the mechanic matters. Near zero means it's "
                  "optional flavour.", "", "| without | organisation win | change |", "|---|---|---|"]
        for k, x in sorted(abl["without"].items(), key=lambda kv: -abs(kv[1] - abl["base"])):
            lines.append(f"| {k} | {100 * x:.1f}% | {100 * (x - abl['base']):+.1f} |")
        lines.append("")
    lines += ["## Known limits", "",
              "- The tactical numbers come from one bot that flies well but plays simply: it follows valleys "
              "and ducks when it sees police, but it doesn't read the police radio or bluff. Humans will do "
              "better on the runner side, so the real task force should be a little stronger than these "
              "numbers suggest.",
              "- The season simulator rolls nights from calibrated probabilities. It captures the economy and "
              "the information war, not flying skill.",
              "- Sample sizes: tactical cells have 3-9 flights each. Anything under about 15 points of "
              "difference is noise.",
              "- Recruit is nearly worthless to a random bot (+2 pts) but the single biggest ablation at "
              "equilibrium (+20.2 pts): it only pays off as an every-night opener, so skilled play finds it "
              "and less-skilled play doesn't. Next candidate fix if this shows up in playtests: a diminishing "
              "recruit success rate after the first informant, so stacking to the cap costs more than the "
              "first one did."]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n")
    return out
