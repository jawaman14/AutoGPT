# What makes a good multiplayer strategic versus game, and how Skyrunner does it

This note connects published design practice to concrete Skyrunner rules.
Wherever the simulators (`godot --headless --script res://scripts/balance/cli.gd`) can measure a principle,
the measurement is named. The measured results are in [BALANCE.md](BALANCE.md).

## 1. Principles from the research

| # | Principle | Source | What it means here |
|---|---|---|---|
| P1 | **Many viable options, no dominant strategy.** A game is balanced if many options are viable, especially at expert level. A dominant move shrinks the game and usually has no counter. | Sirlin, *Balancing Multiplayer Games* parts 1–3 ([part 2](https://www.sirlin.net/articles/balancing-multiplayer-games-part-2-viable-options), [GDC 2009 handout](https://static1.squarespace.com/static/50f14d35e4b0d70ab5fc4f24/t/53ef1dbae4b0a6d424125a6f/1408179642248/GDC+2009+sirlin+handout6.pdf)) | The policy-vs-policy win matrix is checked for dominance, and the equilibrium mix has to use more than one strategy per side. |
| P2 | **Counterplay.** Every offensive action should leave the opponent with *more* answers, not fewer. Also design *teamplay*, the play between teammates. | Tom Cadwell (Riot), GDC 2013, *Counterplay and Teamplay in Multiplayer Game Design* ([GDC Vault](https://gdcvault.com/play/1018158/Counterplay-and-Teamplay-in-Multiplayer), [summary](https://leagueoflegends.fandom.com/wiki/User_blog:JAlbor/GDC_2013:_Teamplay_and_Counterplay_in_League_of_Legends)) | Every tool has a named counter (table in §3). Pilot and co-pilot, and HQ and field crew, need each other. |
| P3 | **Asymmetry through rock-paper-scissors, not mirrors.** When the two sides have different head-counts, balance the *power* of each seat, not the numbers. | [Asymmetric design patterns (Game Developer)](https://www.gamedeveloper.com/design/asymmetrical-gameplay-as-a-new-trend-in-multiplayer-games-and-five-design-patterns-to-make-engaging-asymmetrical-games); [Game Wisdom](https://game-wisdom.com/critical/asymmetrical-game-design); [How to balance asymmetric multiplayer games](https://salivity.github.io/game-development/article/how-to-balance-asymmetric-multiplayer-games) | Runners and law have different tools and different win conditions. Empty seats are filled by full-strength AI. |
| P4 | **Pick a target win rate on purpose.** Dead by Daylight aims for ~60% killer kills because the horror needs the killer to feel strong. But if one side is happy all the time, the other is miserable. | [BHVR forum discussion of the 60% target](https://forums.bhvr.com/dead-by-daylight/discussion/431533/why-60-kill-rate-and-not-55) | Skyrunner has no horror premise, so the target is **50% ± 5 at equilibrium**: whoever plays better should win. |
| P5 | **Hidden movement needs both deduction and deception.** Fury of Dracula improved on Scotland Yard by giving the hunters tools to sense the trail. Pure guessing isn't enough. | [Shut Up & Sit Down review](https://www.shutupandsitdown.com/review-fury-dracula/), [BGG: Fury of Dracula vs Scotland Yard](https://boardgamegeek.com/thread/275401/fury-of-dracula-vs-scotland-yard) | The task force never sees the runner, only radar tracks, tips, DF fixes and visuals. The runner has decoys, terrain masking and patrol leaks. |
| P6 | **Control snowballing, keep comebacks possible.** Positive loops make a lead grow; negative loops let the trailing side catch up. Good competitive games mix the two so a lead matters but doesn't decide the game early. | [Envato Tuts+ on the snowball effect](https://code.tutsplus.com/the-snowball-effect-and-how-to-avoid-it-in-game-design--cms-21892a); [Wayward Strategy on anti-snowball design](https://waywardstrategy.com/2020/07/06/anti-snowball-design/); [Machinations on feedback loops](https://machinations.io/articles/game-systems-feedback-loops-and-how-they-help-craft-player-experiences) | Heat raises the police budget, seizures fund the police but public support drifts back, and both sides have a once-per-season comeback event. Measured as comeback rate and close finishes. |
| P7 | **A commander seat is powerful but intimidating.** Natural Selection 2's RTS-in-FPS commander decides games. Onboarding is its weak spot, and the designers considered restricting the seat to experienced players. | [Natural Selection 2 coverage (Destructoid)](https://www.destructoid.com/natural-selection-2-is-a-fascinating-blend-of-fps-rts/) | HQ seats only appear at layer 5 (five or more players). When nobody takes them, the pilot or controller doubles up, or a competent AI runs them. |
| P8 | **Test balance with agents at equal skill.** Balanced games should give same-skill agents balanced win rates. Treat the strategy set as a metagame (a win matrix) and look at its equilibrium, not the raw averages. | [MCTS agents for strategy analysis](https://awesomepapers.io/ai-agents/papers/1908.01423); [Metagame autobalancing (Hernandez et al.)](https://arxiv.org/pdf/2006.04419); [RuleSmith, LLM agents for asymmetric balance](https://arxiv.org/html/2602.06232); [agent playtesting at scale](https://arxiv.org/pdf/1907.06570) | `strategic.gd` builds the matrix, solves the equilibrium by fictitious play, checks dominance and runs ablations. `tactical.gd` flies the real aircraft. |
| P9 | **More mechanics are not better.** Piling on moves tends to collapse into one or two dominant strategies. | Sirlin, part 2 | Ablations: a mechanic whose removal changes nothing gets cut or reworked, and one whose removal swings the game gets watched closely. |

## 2. Layers: more players, more rules

Every seat needs meaningful decisions every minute (P2, P7), so the rules
stack in layers and the table turns on as many as it can keep busy
(`scripts/sim/layers.gd`, `godot --path . -- --players N`):

| Layer | Adds | Why at this size |
|---|---|---|
| 1 Flight | Weight & balance, fuel, short strips, legal jobs | Learn to fly and load |
| 2 Heat | Contraband, radar, suspicion, police aircraft | One decision: how hot a job to take |
| 3 Crew | Co-pilot, timed loading, airdrops to go-fast boats, cutters, ferry tanks | Gives the second runner and the police boats a job |
| 4 Intel | Scanner vs encryption, detector vs aerostat, spotters, DF, informants | The information war; worth it once each side has a thinker |
| 5 Organisation | A season of nights: HQs, laundering, bribes, evidence, budgets | Two commander seats, only for 5+ players |

| Players | Mode | Layer | Runners (human) | Law (human) |
|---|---|---|---|---|
| 1 | solo | 3 | pilot | AI |
| 2 | versus | 4 | pilot | controller |
| 3 | versus | 4 | pilot, co-pilot | controller |
| 4 | versus | 4 | pilot, co-pilot | controller, police pilot |
| 5 | versus | 5 | pilot, co-pilot, boss | controller, police pilot |
| 6 | versus | 5 | + boss | + chief |
| 7–8 | versus | 5 | + spotter | + cutter captain |

When head-counts differ, the short side's empty seats are AI at full
strength (P3).

## 3. Every tool has a counter (P2)

| Runner tool | Law counter | Law tool | Runner counter |
|---|---|---|---|
| Low flying, terrain masking | Aerostat (20 m floor), helicopter patrols | Radar sites | Valleys, transponder discipline |
| Transponder off | "Squawk lost" alert when a tracked squawk vanishes | Squawk-lost alert | Go dark on the ramp, never squawk |
| Squawk and fly like legitimate traffic | Letdown tell: a squawk that drops off the scope low toward a shady strip is flagged | Strip raids (60 s unload window) | Bush strips instead of shady ones, a patrol leak, an airdrop instead of a landing |
| Radio scanner | Encryption (slower dispatch) | Encryption | A bribed dispatcher leaks it anyway |
| Radar detector | Nothing: it only warns, you still have to act | Informants | Crew loyalty bonuses, counter-intel sweeps, fewer spotters |
| Decoy flights | Visual identification (police pilot), patience | Wiretaps | Burner phones |
| Contract crews | Spread your units; tips | Audits of fronts | More fronts, launder slowly |
| Bribed officials | Internal-affairs sweeps | Asset seizure (budget) | Lawyer on retainer halves bust evidence and flips |
| Airdrops to boats | Cutters on picket, drop-pattern alerts | Patrol zones | Dispatcher leak, route variety |

## 4. Feedback loops (P6)

```
 runner success ──► dirty cash ──► fronts/aircraft ──► more success     (+ loop, capped by laundering capacity)
       │
       └──► heat ──► public pressure ──► police budget ──► more pressure (− loop)
 police bust ──► seizures (80% to the task force) ──► budget            (+ loop)
       └──► support up, then drifts back to 50 every night               (− loop)
 either side 25%+ behind after night 3 ──► comeback event (once)          (− loop)
     law behind:    "Washington sends a federal task force"  (+$10k budget, +10 support)  [South Florida Task Force, 1982]
     runner behind: "the cartel pays more for pilots who'll still fly" (+30% payouts)
```

## 5. Hidden information (P5)

| Seat | Sees exactly | Sees through a source | Never sees |
|---|---|---|---|
| Pilot / co-pilot | Own aircraft, load, boat | Police units: scanner (unless encrypted), spotters, detector, eyes | Radar tracks, evidence |
| Boss | Own books | Evidence: rumour band, exact with lawyer or dispatcher; patrol zone with dispatcher | Informant count |
| Controller | Own units, radar tracks (T1, T2… never names) | Tips, DF fixes, visuals from units | Which track is the real load |
| Police pilot | Own unit; radar tracks as HUD markers | Other aircraft **only while in sight** | Anything out of line of sight |
| Chief | Own budget, evidence | Laundered-cash estimate after an audit or wiretap | Bribes, until IA finds them |

## 6. The historical anchor

The balance numbers borrow their shape from the real 1980s South Florida
fight:

- The [South Florida Task Force](https://en.wikipedia.org/wiki/Organized_Crime_Drug_Enforcement_Task_Force) (1982) is the model for the law's comeback event.
- [Operation Greenback](https://en.wikipedia.org/wiki/Operation_Greenback) followed the laundering money and produced 125 arrests by 1982. That is why audits and front exposure exist.
- The 1984 Comprehensive Crime Control Act let local police keep up to 80% of forfeited assets ([equitable sharing](https://en.wikipedia.org/wiki/Equitable_sharing); [Kantor et al., NBER](https://www.nber.org/papers/w23873)). Hence `seizure_share = 0.8`, and the positive loop it creates.
- U.S. Customs flew radar-equipped Citation interceptors ([CBP](https://www.cbp.gov/newsroom/national-media-release/end-era-amo-retires-c-550-citation)). Hence the interceptor's speed advantage and its wide turning circle against slow twins.

## 7. Seats: every role is the AI's until a human takes it

Every role exists in every game from the first second and the AI plays it: the co-pilot, the
spotter, the go-fast, the boss, the **lieutenant** (the organisation's soldiers on the ground), the
task-force controller, the police pilot, the cutter captain, the chief and the **patrol commander**
(the narcotics squads). A player who joins mid-game sees the live seat list and takes any seat the
AI holds; the AI hands it over at once. Leaving hands it back. Dropping (a lost connection) holds
the seat for 30 s with the AI minding it, and the reconnect token from the welcome takes it back.
`Seats` (`scripts/sim/seats.gd`) is the one table; `Session.seat_driver` flips each system between
its AI and the human, symmetrically, so a seat handed back behaves exactly as before (the boss's
AI planner used to never come back).

Per P3 and P7 this means no seat is ever empty and no table waits for a full house: two friends
can play the pilot and the patrol commander against eight AI seats, and a third can sit down as the
lieutenant twenty minutes in.

### Protocol v3 (TCP, one JSON object per line)

| Direction | Message | Meaning |
|---|---|---|
| client -> host | `{"t":"hello","v":3,"name":"Ana","role":""?,"token":"..."?}` | join; no role = the lobby; a held seat's token takes it back |
| client -> host | `{"t":"claim","role":"lieutenant"}` / `{"t":"release"}` | take a seat from the AI / give it back |
| client -> host | `{"t":"say","text":"...","to":"all"\|"side"}` | table talk |
| client -> host | `{"t":"cmd",...}`, `{"t":"input",...}` | as v2 (only from a seat) |
| host -> client | `{"t":"welcome","role":"","token":"...","mode":...,"seed":...}` | joined |
| host -> client | `{"t":"seats","seats":[{role,side,who,name}],"players":[{name,role}],"you":"..."}` | the live roster, on every change and once a second |
| host -> client | `{"t":"claimed","role":"..."}` / `{"t":"claim_failed","msg":"..."}` | the answer to a claim |
| host -> client | `{"t":"chat","from","role","side","text","to"}` | table talk (side talk only to that side) |
| host -> client | `{"t":"snap",...}` | role-filtered snapshots, only to players in a seat |

v2 clients that name a role in the hello still go straight into it.

From the game: the lobby's **Join** with "pick a seat" (or `--connect HOST:PORT --role pick`) opens
the seat picker; `--role lieutenant` or `--role patrol` sits straight down at those desks.
