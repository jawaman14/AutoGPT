class_name BalanceReport
extends RefCounted
## Build docs/BALANCE.md from saved simulation results (sim-results/*.json).
## Port of skyrunner/sim/report.py; the changelog below is copied verbatim.

## What the simulations changed, oldest first. Numbers are from the runs that
## motivated each change; the tables below are regenerated from current code.
const CHANGELOG := [
	["Pine Ridge was a trap",
		"Feasibility sweep: a C172 could land at PNR but only take off again with <25% fuel. The 22 m tree lines 60 m past each runway end blocked any loaded climb-out.",
		"Tree lines moved to 110 m past the ends and cut to 16 m (the 50 ft obstacle a pilot's handbook plans for). A C172 now gets out at every load the sweep tries."],
	["Old Quarry was a trap",
		"No aircraft could take off from QRY in either direction: a 13 m rim just past the downhill end, and the pit wall (215 m in 240 m) past the other.",
		"Added a graded haul road out of the downhill end (`Airfield.haul_road`). QRY becomes a one-way strip: land uphill, take off downhill. It stays the hardest strip on the island."],
	["Narrow strips had no way to turn round",
		"A 180-degree pivot needs about 13 m, more than the width of QRY (12 m) or PNR (15 m). Backtracking for a downhill takeoff left you in the rough.",
		"New actions: differential toe-brakes for pivot turns (`Controls.diff_brake`), and 'push her round' (key I, 20 s solo or 10 s with crew), which is what bush pilots actually do."],
	["Flying under the radar never worked",
		"Tactical sweep: low-level runs with the transponder off were flagged 100% and busted 78-100%. Squawking like legitimate traffic delivered 89% against light police. That is the opposite of the history, and it made one tactic dominant.",
		"A primary-only radar track now builds suspicion slowly (1.2-4.2 %/s instead of 8-33 %/s), so it takes 30-60 s of sustained track. Behaviour multiplies it: low and fast inbound from the sea x2.5, orbiting low over water +3 %/s, a squawk that vanishes mid-track +50. The aerostat's 20 m floor is the counter to low flying."],
	["Then hiding in plain sight became dominant",
		"With the radar fix in, squawking like legitimate traffic delivered 73-100% of loads and was never flagged by light or standard police. Only an informant's tip stopped it. The quarry sits in radar shadow, so nothing saw where the 'legitimate' flight went.",
		"Two linked rules. (1) A squawking track that drops off the scope low and heading for a shady strip is flagged at once ('nobody legit lands at Old Quarry'); a bush strip only earns +30 suspicion, because honest jobs go there too. (2) A hot load at a bush or shady strip takes 60 s to unload, and a police aircraft within 2 km in that time means a raid. The tell now has consequences: the task force races you to the strip, and a patrol parked nearby wins the race."],
	["Coast Guard cutters never caught anything",
		"0% boat seizures across 189 flights: cutters sailed from Port Harbor, 20 km away at 32 kt, and the go-fast was gone in 5 minutes.",
		"A funded cutter starts the night on picket off the coast (`Maritime.new_cutter(at=...)`). Seizures appear (13-17% of sea runs in later sweeps) without making airdrops pointless."],
	["The law won 81% of seasons",
		"First strategic run: the runner equilibrium win rate was 0.18. Retiring rich happened in 2% of seasons, bribery cut win rate by 18 points, and wiretaps added 43 points.",
		"Retire target $90k -> $60k; run payout $11k -> $13k; contract crews cheaper ($4k -> $3k) and better paid (50% -> 60% share); bribes cheaper; wiretap 7 -> 4 evidence/night (warrant at 20 evidence, $7k); audits worth more (3.5 -> 6 per exposure point, $5k -> $4k); seizure share 50% -> 80% (the 1984 equitable-sharing rule); encryption $8k -> $5k; new runner order 'gear' (scanner/detector) so encryption has something to counter; comeback gap 30% -> 25%. Equilibrium: 0.18 -> 0.30 -> 0.49 -> 0.50."],
	["Calibrated to flown numbers, the law won 98%",
		"Once the season simulator used rates flown by the bot instead of hand estimates, the organisation's equilibrium win rate fell to 2% and 48% of seasons ended broke. Three causes: the aerostat's 40 km radius covered every route on the island; the abstract model treated five police units as five times one; and every bust fed the case against the boss, a snowball.",
		"Aerostat radius 40 -> 22 km (south coast and sea lanes; the northern mountains are the way round it). Interception now has diminishing returns (`k * ln(1 + units)`, with k fitted to flown flights). Units cost more (helicopter $3k -> $4k, interceptor $5k -> $7k, aerostat $4k -> $6k). A contract crew's bust gives 2 evidence and never flips, because they don't know who they fly for. Bust evidence 12 -> 6; wiretap 4 -> 3; bankruptcy at -$10k. A bribed dispatcher's warning now reroutes the run away from the patrol and the balloon. Economy: run value $15k, retire at $45k, start with $16k, police base budget $9k. A 16-point grid search picked the last four. The bot's low-level crash rate is capped at 6% in the calibration, because it overstates a competent human. A smarter organisation bot joined the pool so both sides have one strategy that uses all its information (principle P8: balance at equal skill). Equilibrium: 0.02 -> 0.09 -> 0.25 -> 0.37 -> 0.475."],
	["The test rig itself was wrong once",
		"'aerostat' and 'standard' postures gave identical numbers because the Session raises the aerostat automatically whenever the feature is on.",
		"Fixed in the rig (the aerostat is available but only raised by the posture). Lesson: check that configurations which should differ actually do, before believing the numbers."],
	["Recruiting an informant was the single best move in the game",
		"At 8000 seasons the equilibrium (organisation win 45.5%) looked fair, but the ablation table told a different story: removing 'recruit' alone swung it to 60% (+14.5, the biggest number on the board). Reading the code found why: an informant gave three stacked, always-on bonuses (a flat +45% detection chance on tip nights, a 1.2x intercept-hazard multiplier on top of that, and 2.5 evidence/night per head, up to 3 heads) for $3k plus $1k/night upkeep, and a whole computed 'informant_mult' field was dead code that never reached the resolver. Worse, 'cautious' - the equilibrium runner strategy - never called 'counterintel' at all, so the one built-in counter to informants was never used by the side that was actually winning.",
		"Informant cap 3 -> 2; recruiting cost $3k -> $5k; evidence/informant 2.5 -> 1.8; the tip's detection bonus +45% -> +30% and its intercept-match multiplier 1.2x -> 1.1x; counterintel cheaper ($5k -> $4k) and burns 75% of informants instead of 60%. Removed the dead 'informant_mult' field instead of wiring it in on top of the tip bonus, which would have doubled up the same effect. Gave 'runner_cautious' a counterintel response whenever it already reaches for opsec (serious evidence rumour or heat > 70), matching what 'adaptive' and 'smart' already did. Equilibrium: 0.455 -> 0.450 at 40000 seasons; the investigation trio (recruit/audit/wiretap) still swings the most on ablation (+15 to +20 points each), which tracks with evidence being the task force's only win condition, but it is now measured, not accidentally doubled by dead code."],
	["Recruiting a second informant was still nearly free",
		"Known limits flagged the fix above as partial: recruit's ablation stayed the single biggest number (+20.2) because the cost and odds only depended on the informant cap, not on how many were already in place. Stacking to the cap (2) cost the same $5k twice and succeeded at the same rate twice, so a chief who could afford it just always went to 2 early and never felt a choice.",
		"Recruiting cost now scales with the count already turned ($5k, then $10k for the second), and the success chance is multiplied by 0.6 per existing informant, so the second head is a real, worse bet rather than a free top-up. Equilibrium barely moved (0.450 -> 0.451 at 40000 seasons) because most of recruit's value is 'have one at all' versus 'have none', which this doesn't touch - that first informant is doing the work the task force's whole case-building game is built on. The remaining ablation size is now read as by-design (evidence is the task force's only win path) rather than a bug, per the note above."],
	["The balance rested on 9-flight calibration cells",
		"Porting to Godot, the season simulator reproduced Python's numbers exactly, yet the Godot build's own tactical sweep (same seeds) produced an equilibrium of 69% instead of 45%. 130 of 189 flights were identical; the rest diverged because the pip JSBSim and a source-built JSBSim differ by a few ulps in longitude, and a flight near a bot decision threshold amplifies that. Totals matched (109 vs 109 flagged), but the calibration fits each zone from 9 flights, so a handful of flipped outcomes moved intercept_k from 2.0 to 1.3 and the season result by 24 points.",
		"The tactical sweep now flies 10 seeds per cell (630 flights). intercept_k settles at 1.96, next to Python's 2.03; west-route detection is higher than the small sample said (0.47 vs 0.22). Lesson: a calibration built on a single-digit sample is a coin toss, however exact the simulator downstream."],
	["A second smuggling outfit: Los Cuervos",
		"Requested feature: competing smuggler groups. Added a rival cartel run by the AI on its own random stream. It flies loads every night, splits the police, undercuts payouts where it owns the market, and hijacks your load if you share a route without a truce. The boss can hit it, buy a truce or sell its route to the police; the chief can send a gang unit. With the new calibration and the cartel on, the organisation's equilibrium was 39% (44% with the cartel off).",
		"A 12-point grid over the cartel's market bite, its hijack chance and the retirement target. Retire at $38k (was $45k), market loss 30% at full rival control, hijack chance 20% + 30% x strength when you meet on the same route. Equilibrium 48.8% over 40,000 seasons, every ending between 13% and 27%, comebacks 21%. The cartel hijacks at least one load in a third of seasons, and recruit's ablation swing fell from +20 to +8 points: the cartel gives the task force a second target and the organisation a second enemy."],
	["Heavy police flew exactly like standard police",
		"Tactical sweep, 90 flights per posture: 'heavy' (2 helicopters, 2 interceptors) and 'standard' (1 + 1) gave identical rows, flight for flight. The AI sends a fixed response per wanted level (1 helicopter, then +1 interceptor, then +1 more), so a second helicopter never left the ground: the chief's extra money bought nothing.",
		"First try, a stake-out: a spare helicopter flew to the strip the track seemed to be making for. It guessed wrong against routes that dog-leg round radar cover, and changed no flight. Second, the surge (asked for: the spare joins the chase): every spare helicopter launches after a wanted track as a flanker, aiming up to 90 s ahead of the runner to cut it off, and two aircraft within bust range fill the bust meter 50% faster (boxed in). Re-flown, heavy still matches standard flight for flight, and the reason is now clear: of the 38 flights standard police flag, one helicopter busts 29, 6 end in the bot's own hard landing or ditching, and 3 get away over the sea. There is nothing left for a second chaser to win. Extra helicopters pay before the chase, not in it: the patrol posture (one helicopter already over the zone) busts 40 of 90 against 29. The season model credits extra units with ln(1 + units), 1.49x the hazard for heavy; flown, it's 1.00x (see section 2). Third, and kept (asked for: patrol before the run instead): the AI keeps one helicopter for the chase and flies every spare over a zone before the run - in the live game where the analysts expect the organisation, in the sweep a seeded draw because the police don't know the route. A spare that spots a runner becomes the flanker. Re-flown with the airdrop fixes below: heavy intercepts 32 of 90 against standard's 29, busts equal at 28. Patrolling spares find a few more runners; one helicopter over the right zone (the patrol posture) still does far more, so the chief's money is best spent on a patrol order, not on more hangar space."],
	["Weather and the moon",
		"Requested: realism. Each night now has a forecast both HQs see while planning (clear 55%, cloud 30%, storm 15%, right 75% of the time) and a moon on a 29.5-day cycle. Cloud, rain and a dark moon cut how far crews see; storms ground most helicopters and the aerostat (TARS balloons are winched down for lightning), make the sea too rough for cutters, and more than double crash risk. Live: JSBSim wind and Dryden turbulence, rain, lightning, a storm deck, the moon's phase. The first version handed the organisation 69% (weather was a flat -16% on detection). Centring the factors on 1.0 (clear x1.1, cloud x0.9, storm x0.7; moon x0.8-1.2; crashes x0.8/1.1/2.2) still left it at 62%: attribution runs (one storm effect off at a time) put ~5 points on visibility, 1 or less each on grounded helicopters, balloon and cutters, the rest on interactions (the law bots learn less from fewer sightings). That matches history: smugglers picked bad weather and dark nights.",
		"Kept the realism and moved the economy instead: retire target $38k -> $48k (with the pattern rule below at 0.45). Equilibrium 51.2% over 40,000 seasons, endings 14-28%, comebacks 22%. Weather is now worth about 13 points to the organisation on ablation - the biggest single lever in the game - so reading the forecast is part of playing well."],
	["Pattern of life: predictability is exploitable",
		"Game theory's inspection game (police vs smuggler) has no pure-strategy equilibrium: whoever is predictable loses. The old abstract model had no memory, so flying the same route every night cost nothing (the greedy bot flew the sea every night, 0 bits of route entropy). Real task forces keep sighting logs and patrol where the pattern points.",
		"The law's analysts now add up to +45% detection on a route, scaled by the share of the last four nights' sightings that fell there; both HQs see the numbers. The runner bots now weight their route choice away from that exposure. Ablation: switching it off hands the organisation ~5 points; route entropy runs from 0 (greedy) to 1.5 bits (cautious, shadow; 1.585 is uniform), and the most mixed strategies are detected least."],
	["The canary trap",
		"Real counter-intelligence tests a suspected leak by feeding a unique false detail down one channel and watching whether it comes back. Added as a chief order ($1.5k): the bribed dispatcher passes on a fake patrol; if the organisation's plan swerves around a patrol that never flew, the dispatcher is arrested (+12 evidence). The first version made the law worse off (-5 points): the adaptive chief sprang it after any single missed patrol, which is usually just luck, and it caught a leak in 3% of seasons.",
		"The chief bot now waits for two evaded patrols. The canary is neutral at equilibrium (+/-1 point) and catches a leak in ~2% of seasons: a niche counter that matters against dispatcher-reliant play. It also makes every leak an uncertain signal, which is the point: the organisation can no longer treat the dispatcher as ground truth."],
	["Truces unravel near the end",
		"A truce with Los Cuervos is an iterated prisoner's dilemma: cooperation holds while the future is worth more than one betrayal (the shadow of the future). Backward induction says it collapses as the season runs out. Each season Los Cuervos now get a hidden temper - tit-for-tat, grudge-holder or opportunist - that the organisation learns from how they behave. Opportunists sell your route to the task force, most often in the last two nights; grudge-holders never make peace after you hit or sold them; tit-for-tat answers your last move.",
		"Measured over 40,000 seasons: betrayals land at 157 each with 1 and 2 nights left, 142 on the last night, against 20-90 on any earlier night; opportunists betray 0.055 times per season, tit-for-tat 0.004, grudgers never. The runner bots now refuse to pay for a truce with a known opportunist near the end, and defect first on the last night. Ablation: ~1 point, because truces are rare in the bot meta - it matters to humans who read the reputation line."],
	["The pilot's nerves",
		"Requested: psychology. Stress now follows what real smuggling pilots feared (wanted level, a police aircraft in sight, low flying in the dark or a storm, fuel running out; a crew in the right seat takes 25% off), rising in seconds and settling over half a minute. Following the Yerkes-Dodson curve, moderate arousal costs nothing; above 0.6 the screen tunnels and drains of colour, the heartbeat becomes audible and an 8-12 Hz tremor (the band adrenaline amplifies) is added to the stick.",
		"Human hands only: the bot and the autopilot are immune, so none of the numbers in this report move. It is a skill tax that rewards staying calm - a co-pilot, altitude, fuel margin - rather than a dice roll."],
	["The pilot bot couldn't make most airdrops",
		"The co-pilot simulator (section 6) flew the sea mission solo, with the AI co-pilot and with a scripted human one, and most flights 'gave up: couldn't get the bales out'. The bot orbited the rendezvous at 500 m; bales can only go out within 450 m. Inherited from the Python bot, so every sea row in every earlier sweep was a failed drop. Worse, a go-fast that fled a cutter ran home empty and reported 'delivered 0 bales', which closed the job before the plane arrived, and the tactical sweep counted those flights as delivered.",
		"The bot now orbits at 250 m (it flies about 400 m at its bank limit) and abandons a drop when the boat has gone; a boat that fled empty waits the cutter out and goes back to the rendezvous; only bales that reach the cove count. Sea detection went from 13% to 33% (the plane now loiters over the drop), and the calibration moved: intercept_k 1.96 -> 1.35, bust given intercept 0.90 -> 0.78. That handed the organisation 70% at equilibrium, so the economy was retuned on a grid: a run pays $12k (was $15k), overhead $1,500 a night (was $1,000), retire at $52k (was $48k). Equilibrium 50.4% over 40,000 seasons, every ending between 10% and 34%, comebacks 21%. Python parity replays keep the old rules (Tactical.PYTHON, HQ.PYTHON_RULES)."],
	["Radio discipline: calling the boat can sink the run",
		"Section 6: the AI co-pilot got 27% of the bales to the cove, the solo pilot 10%, and a scripted human co-pilot who radios the boat on the way in only 2%. The call is a transmission: the task force's direction finders get bearings, the case against the runner jumps, and the cutter goes where the boat is heading. The boat already knows the rendezvous; talking to it is a gift to the other side.",
		"No rule change: the mechanic works as the designers of real smuggling ops learned it (radio silence, pre-arranged marks). The co-pilot's desk shows the DF risk on the call-the-boat row so a human learns it without losing a season to it."],
	["Real radar and radio moved the calibration, not the balance",
		"Requested: radar and radio realism. Radar now has the 4/3-earth horizon, sea and rain clutter, an MTI notch (a primary set cancels anything with little radial speed), per-site scan periods (4.8 s, the aerostat 12 s), probability of detection by range and aircraft size, trails, Mode C and real squawk codes. Radio has VHF line of sight over the terrain, separate channels, call length setting DF quality, and a least-squares fix with an error ellipse. Re-flying all 630 tactical flights under the new rules: detection on the low west route fell 0.47 -> 0.33 and in the north 0.67 -> 0.53 (the horizon and the notch hide low valley flying from the ground sets, as they did in reality), while the aerostat, looking down from altitude, saw more (west 0.20 -> 0.33, north 0.00 -> 0.13). intercept_k 1.35 -> 1.38, bust given intercept 0.78 -> 0.79.",
		"No retune needed: the season model on the new calibration gives the organisation 50.2% at equilibrium over 40,000 seasons (was 50.4%), every ending between 10% and 34%, comebacks 22%. The two effects cancel: ground radar got worse at low flyers, the balloon got better, and the equilibrium strategies already route round whichever the chief bought. The aerostat is now the counter to valley flying rather than only to the sea lanes."],
	["Upgrade trees, stash houses and markets live outside the season model",
		"Requested: espionage, counter-surveillance and weaponry on upgrade trees; a city-coast map with stash houses; an economy where prices move with rivals, police, goods and fuel. All three act on the live game: tree nodes change sensor ranges, DF, boarding and raid odds; stash runs add a truck leg the police can stop; markets move what a load pays. The season simulator abstracts nights into zone probabilities and a fixed run value, so it doesn't see any of them.",
		"Deliberately left out of the equilibrium: each is roughly symmetric (every runner node has a law counter - burst radio vs DF, spoofer vs the fused picture, mole vs mole hunt, armed boat vs fast cutter; a busy stash heats up and gets raided; a market the runner floods pays less), and the AI chief buys law upgrades only in live play, as forfeiture comes in. Their tests pin the mechanics (tests/test_upgrades.gd, test_city_map.gd, test_economy.gd); balancing them is a playtest job, listed under known limits."],
	["The live-play systems got their own simulator",
		"Requested: a balance run after the Family, Isla Soberana and the Company's double game went in. None of them are in the season model, so tools/live_balance.gd steps them directly (80 seeds x 3 simulated hours x 5 configurations; flown runs stand in as income). First run: a mule lost money in every case (ROI -0.77 to -0.86: $364 of 'sugar' for a $1,540 cost); the Family was convicted in 100% of runs because the RICO case drifted 0.3/min on its own (+54 in 3 h); respect bled to 15-19 because every declined offer cost 3 points and nothing brought it back. After a fix, the island dominated: $133k median against $70k for the control, a shipment every 10 minutes at ROI ~1.0 and our perks cancelling the task force's kit.",
		"A mule carries a kilo of the pure product ($1,400 cost, worth $2,600); a container pays the shipping line $6,000; X-ray and inspections double the odds instead of x1.7/x1.5; the island's connection restocks each route every 20 minutes; each load that gets through warms that route (+2 heat a mule, +8 a container). RICO filings cost $4,000 and add 5-10 (+6 with a rat); the case drifts 0.1/min; a declined offer costs 1 point of respect and respect drifts back toward 50; the street tax comes at most every 45 minutes. Now: ROI per load 0.67-0.69 cold, 0.11-0.16 against the task force's whole kit and a crackdown, 0.76-0.81 with our perks; the island config ends level with the control after paying for the perks (the payoff is in longer play); the Family costs about $15k in 3 h, mostly tribute, with a rat in 4-25% of runs and a trial in 0-6%."],
	["Hired hands, paid or else",
		"Requested: NPCs using the systems, and cartels that have to hire and pay their workers. Soldiers, drivers, mules, lookouts, accountants and contract pilots now come off a payroll (both outfits), paid every 10 minutes; the unpaid turn (skim, walk or call the task force), the arrested get cases and may flip. The worry was a wage bill that starves the organisation. The live simulator (a 'payroll' configuration, the AI hiring to its needs) says it roughly pays for itself: $12k of wages over 3 hours against contract pilots' runs and the accountant's cooling of the case; with every live system on, it costs about $9k net.",
		"No retune: loyalty ends high (0.84-0.88) because the AI pays on time, which is the point - the risks bite a player who hires cheap, pays late or leaves the jailed without lawyers. Worth playtesting whether the street hires (drivers, mules) should cost more."],
	["The trade: dealers, buyers, and grass before cocaine",
		"Requested: street sellers and buyers of the product (the Mob and the Company), selling them guns to move the wars and gun prices, and marijuana as the cheap way in, as in the cocaine cowboy stories. The organisation now holds stock; dealers (a payroll role, both outfits) sell it on the corners, bulk buyers take it at a discount, rifles go to the Family, the Company or Los Cuervos with different consequences. First live run: the stand-in AI bought a load every 15 minutes whatever the stash held and ended runs sitting on ~1,000 lb of unsold cocaine - money down to $61k (trade) and $44k (all systems).",
		"The AI buys a load only when the stash runs low (under 150 lb of cocaine / 800 lb of grass); dealers move 0.6 lb of cocaine or 5 lb of grass a minute; buyers pay 72-85% of the street for drugs and 100-130% of the fence for rifles, with 30-minute appetites; the Colombians call after 1,200 lb of grass (or $25k made). Now the trade config ends at $72k cash plus ~$20k of product in the stash (control $70k), with the connection at ~75 minutes. With every system on and the career: $58k cash plus ~$21k of product (was $73k) - the island and cocaine work only open once the Colombians call, which is the point of the career; worth watching in playtests whether the first hour of grass feels too slow."],
	["The street: supply, demand, and cocaine for guns",
		"Requested: prices and supply that move with events, competing factions and arrests, and the Company buying cocaine to buy guns as in the Contra era. A supply-and-demand layer went under the price walk (arrests and raids break networks, rival shipments flood, the island and the Family move the source), and the Company runs a cocaine-north, guns-south pipeline. The first live run found three double counts: the island's shortage and glut were priced twice (its own price and the source); our own deliveries flooded the street twice (the old glut and the new supply); and island loads paid a fixed value while their cost followed the wholesale, so every shock only hurt. The island median fell $69k -> $62k and the pipeline's trail pushed the Company's exposure from 33 to 62 in three hours (hung out in 20% of runs).",
		"Shortages and gluts now reach the street only; supply ignores our own deliveries (the glut term has them); island loads are paid at today's street price when they land (mules and containers in town); an airport crackdown shortens the town's supply instead of the source; the restock slows with the square root of a short source; the pipeline leaves 0.75 exposure a lot. Now: island median $67.8k (was $69.3k), all systems $72.9k (was $76.2k - the pipeline's cheap cocaine), the Company $91k (was $94k), hung out in 2.5% of runs. Guns average x1.37 with the Company buying (x1.12 without). In a quiet market the island's return per load reads lower (mules 0.56 cold, was 0.67), because Los Cuervos' standing undercut is now in the price; in play the law's crackdowns tighten the street and give it back."],
	["The story, and stock and cash that have to be moved",
		"Requested: a storyline where the game opens up chapter by chapter, with a mode that has everything from the start; then logistics - stock and cash physically somewhere, moved to the buyers and the sellers. The story's eight chapters build each system when it opens (on its own stream); logistics puts product in the stash houses and street money where it's made, so the corners sell only what's local, bulk lots are trucked to the buyers' meets and the money trucked back, and the club's safe pays for everything. First runs: the story's AI stalled in 1980 for four hours - it trucked cash home only past $15k a stash, and street money builds at about $100 a minute; and with the street war stepped, the organisation went broke with suspicion pinned at 100, with or without logistics.",
		"The balance tool doesn't step the street war (no police aircraft or suspicion decay to set against its firefights - the tactical sweeps cover it), and said so. The AI now collects any stash's cash ($1,000+) after 20 minutes and batches past $8k, one cash truck at a time; product moves at most every 10 minutes; a seized cash truck is a money-laundering lead (+4 suspicion), not a drug case. A faction that's gone (the Commission trial, the Company cutting us loose) can't strand a chapter. Now: logistics costs the stand-in AI about 8% of the trade config's net worth over three hours ($55.8k in the safe and $10.4k still out, against $71.8k; about $900 and 120 lb lost a run); the story's AI reaches 1981 at about three hours, 1986 in every run, and finishes in 72% of 12-hour runs (section 7)."],
	["The street war, measured",
		"The live-play simulator now steps the street war (entry 28 left it out). It stands in for the police's own cooling of the case between flown runs, a tenth of PoliceSystem's rate, because the war keeps them looking. First run: $26k against $58k for the same systems without the war. The organisation's AI rebuilt squads whenever it held $12k and bought rifles past $15k; it paid eight soldiers whether or not it fielded squads; it hired a $2,000 lawyer for every corner dealer the war put in a cell. In the story, the trucks drove into checkpoints and patrols, the stashes burned (4 of 8), and only 7.5% of runs got past 1982.",
		"Now the organisation's AI:\n- keeps $30k in reserve before it spends on the war;\n- raises a squad at most every 30 minutes, only when it has none or Los Cuervos outnumber it;\n- pays soldiers for the squads it fields plus one in reserve;\n- hires lawyers only for the jailed who know a lot.\nDrivers pull over when they see police on the road ahead; a passing patrol pulls over a truck a quarter of the time (half if it's heading for a known stash), where a checkpoint stops them all; a van between our own places heats a stash a third as much as a load off an aircraft, and a cash truck to the club leaves nothing to tail. The story's money goals scale to a war economy ($40k in the bank in 1982, $200k to finish). The war now costs about a fifth: $50.0k against $62.5k over three hours. In the story: 1983 in 98% of 12-hour runs, 1986 in 73%, the end in 43%. Then guns went physical (a sale is trucked from the armoury to the buyer): the Company's rifles cross Los Cuervos country to the hangar up north, and the stand-in AI, with no escort to spare, reached 1986 in 43% and the end in 25%. So the Company collects at the strip nearest the goods (its plane, as the Contra supply flights did) instead of a hangar up north: 1986 in 65%, the end in 30%. Last, the stand-in's flown runs now count as the pilot's deliveries (every other one hot), as a player's jobs do; that exposed a money crunch before the island (payroll and bad news ate the flown runs' $18k an hour), so 1982 asks $30k in the bank and 1984 one load from the island: 1983 in 95%, 1986 in 90%, the end in 75% of 12-hour runs (section 7). Once it opens, the island is the money engine ($150k-$800k in the long runs): its long-game balance is the next thing to watch (entry 30)."],
	["Isla Soberana lands as stock",
		"Entry 29 left the island as the long game's money engine: a cleared container or a mule run paid its pounds at the street price straight into the bank - 500 lb sold at once, with no dealers, buyers' caps, stash or trucks, where every other load had gone through logistics since entry 28. A container cost about $15k and was worth about $27.5k, found 8% of the time: about +$10k every 20 minutes, $150k-$800k over a 12-hour story. Now, with logistics on, the island's product lands in a stash: a container in the stash by the docks, mules' pounds in the one by the airport (the same place, Warehouse 7 by the port; the nearest stash if it's burned), and it's sold like any other load, as fast as the corners and the buyers take it. Without logistics the old payout stays, so every other config is unchanged.",
		"The story's stand-in buys from the island only when the stash runs low (under 150 lb, as it buys its own loads), except to bring the 1984 chapter's one load. It spends about $28k a run there now. The 1986 goal, $200k, was set against the island's payouts: the best net worth in 1986 is now $57k-$133k (median about $90k), so the Kingpin asks $80k in cash, product and street money. 1986 in 90% of 12-hour runs, the end in 70% (section 7); the other configs reproduce entry 29."],
	["Flights that can go wrong",
		"The live-play simulator didn't fly: runs were a fixed income, so a bust's fine (at least $1,500 plus a quarter of the bank, or the court's bail and lawyers once it opens), the cash bags seized aboard and a crash's repairs never happened, and the story's goals rested on that. First try: roll each flight against the pooled calibration (every tactic the bot flew, evenly). That busts a quarter of all flights; over 12 hours the story's pilot was busted 12 times, paid $52k in fines, and finished 7.5% of runs, most of them stuck in 1982 with the bank goal eaten a quarter at a time. No player keeps flying low into a standing task force.",
		"Now each flight rolls what the tactical sweep measured for the police's posture as the session has it (tipped off at suspicion 60+, the balloon up, or heavy / standard / light by units in stock), flying the tactic that did best against it - high, against standard police: 0 of 30 busted - and stays on the ground when even that one is busted more than a quarter of the time (AirRisk). A flight every 15 minutes (the bot's took 13-19), paying so the mean income is the stand-in's; busts and crashes go through the session. Three hours, all systems with logistics, the war and the court: money p50 $16.6k against $23.8k at a fixed income, from 0.6 busts and 0.7 crashes a run - a bust in the court costs bail, lawyers and the bags aboard. The story: about 2 busts and 2 crashes, $8k in fines and $5k in repairs a run; 1986 in 80% of runs, and at $80k the end in 42.5%. The best net worth in 1986 of the runs that fell short was $46k-$80k, most of them $68k-$80k, so the Kingpin asks $65k: the end in 67.5%. Last, island product had landed unseen: it now warms its stash as any load arriving does (a pickup from the port is traffic too), and raids took $10.3k a story instead of $9.7k; the end in 65% (section 7). The other configurations don't fly and reproduce entry 30."],
]


static func _load(dir: String, name: String):
	var p := dir.path_join(name + ".json")
	return JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null


static func _pct(v) -> String:
	return "-" if v == null else Py.f(100 * float(v), 0) + "%"


static func _signed(x: float, n: int) -> String:
	var s := Py.f(x, n)
	return s if s.begins_with("-") else "+" + s


## Python repr of a float (shortest round-trip form, "1.0" for integers).
static func _repr(v) -> String:
	if v is float:
		return Py.float_repr(v)
	if v is Dictionary:
		var parts := []
		for k in v:
			parts.append("'%s': %s" % [k, _repr(v[k])])
		return "{" + ", ".join(parts) + "}"
	return str(v)


static func cal_repr(cal: HQ.Calibration) -> String:
	var d := cal.to_dict()
	var parts := []
	for k in d:
		parts.append("%s=%s" % [k, _repr(d[k])])
	return "Calibration(" + ", ".join(parts) + ")"


static func write_report(results_dir: String, out_path: String) -> String:
	var lines := ["# Skyrunner balance report", "",
		"Generated by `godot --headless --script res://scripts/balance/cli.gd -- report` from the raw runs in "
		+ "`sim-results/`. The method and the reasoning behind the targets are in "
		+ "[MULTIPLAYER.md](MULTIPLAYER.md).", "",
		"**Targets.** Equilibrium win rate 50% ± 5 for same-skill play. No dominant strategy. At least two "
		+ "strategies per side in the equilibrium mix. Every win condition happens in at least 8% of seasons. "
		+ "Comebacks (the side leading at half-time loses) in 15-35% of seasons. No airfield you can land at "
		+ "but can't leave with the aircraft that got you there.", ""]

	lines += ["## What the simulations changed", ""]
	for i in CHANGELOG.size():
		var c: Array = CHANGELOG[i]
		lines += ["%d. **%s.** *Found:* %s *Changed:* %s" % [i + 1, c[0], c[1], c[2]], ""]

	var feas = _load(results_dir, "feasibility")
	if feas:
		var ok := Py.count(feas, func(r): return Py.truthy(r["ok"]))
		lines += ["## 1. Can you get in and out? (feasibility)", "",
			("The pilot bot flew %d takeoffs and landings: every aircraft × airfield × load " % feas.size())
			+ "(light = 30% fuel; half = 60% fuel + half payload; max = full fuel + payload to MTOW). "
			+ ("%d succeeded. L = landing, T = takeoff." % ok), "", Feasibility.table(feas), "",
			"How to read it: the C172 row is the one that matters for fairness, because every career "
			+ "starts in one. It lands everywhere at light and half loads and takes off from everywhere "
			+ "except the quarry at half load. At max weight it can't leave the plateau (EGL) or the "
			+ "quarry. That is the trade-off the game is built on: tight strips mean light loads. The PA28, C182 and Twin Otter "
			+ "rows mostly measure the bot rather than the aircraft. It was tuned on the C172 and C310, and "
			+ "the PA28's JSBSim model needs about -0.6 elevator of trim at approach speed. Treat red cells "
			+ "there as 'the bot can't', not 'a human can't'.", ""]

	var tac = _load(results_dir, "tactical")
	if tac:
		var missions := []
		for k in Tactical.MISSIONS:
			missions.append("%s: %s->%s" % [k, Tactical.MISSIONS[k][0], Tactical.MISSIONS[k][1]])
		var laws_seen := {}
		for r in tac:
			laws_seen[r["law"]] = true
		lines += ["## 2. Cops vs smugglers, flown (tactical)", "",
			("%d real flights: the pilot bot (C172) against the AI task force. Three missions " % tac.size())
			+ "(" + ", ".join(missions) + "), "
			+ ("%d police postures, three runner tactics: *low* (50 m, " % laws_seen.size())
			+ "transponder off, valley routing), *high* (450 m, squawking like legitimate traffic) and "
			+ "*evasive* (low plus scanner, detector and evasion).", "",
			"| | n | flagged | intercepted | busted | crashed | delivered | boat seized |",
			"|---|---|---|---|---|---|---|---|"]
		var row := func(label: String, w: Dictionary) -> void:
			var q := Tactical.rates(tac, w)
			if q.get("n"):
				lines.append("| %s | %d | %s | %s | %s | %s | %s | %s |" % [label, q["n"], _pct(q["flagged"]),
					_pct(q["intercepted"]), _pct(q["busted"]), _pct(q["crashed"]), _pct(q["delivered"]),
					_pct(q["boat_seized"])])
		row.call("**all**", {})
		for t in Tactical.TACTICS:
			row.call("tactic: " + t, {"tactic": t})
		for law in Tactical.LAW_CONFIGS:
			row.call("police: " + law, {"law": law})
		for z in Tactical.MISSIONS:
			row.call("zone: " + z, {"zone": z})
		var laws := Tactical.LAW_CONFIGS.keys().filter(func(law): return Tactical.rates(tac, {"law": law}).get("n"))
		lines += ["", "Tactic × posture (delivered):", "", "| tactic | " + " | ".join(laws) + " |",
			"|---|" + "---|".repeat(laws.size())]
		for t in Tactical.TACTICS:
			var cells := laws.map(func(law): return _pct(Tactical.rates(tac, {"tactic": t, "law": law}).get("delivered")))
			lines.append("| %s | " % t + " | ".join(cells) + " |")
		lines += ["", "Calibration fed to the season simulator: `%s`" % cal_repr(Tactical.calibrate(tac)), ""]
		var ur := Tactical.unit_returns(tac)
		if not ur.is_empty():
			lines += ["Returns on extra units: heavy (2 helicopters + 2 interceptors) vs standard (1 + 1) intercept hazard, flown "
				+ "%sx, season model %sx. The season model prices extra units with ln(1 + units); the closer the two, "
				% [Py.f(ur["flown"], 2), Py.f(ur["model"], 2)] + "the better it prices the chief's helicopters (entry 14: spares patrol before the run).", ""]

	var strat = _load(results_dir, "strategic")
	if strat:
		var mx := Strategic.matrix(strat)
		var R: Array = mx[0]
		var L: Array = mx[1]
		var m: Array = mx[2]
		var eq := Strategic.equilibrium(m)
		var p: Array = eq[0]
		var q: Array = eq[1]
		var v: float = eq[2]
		var s := Strategic.summary(strat)
		lines += ["## 3. Whole seasons, HQ vs HQ (strategic)", "",
			"%d simulated seasons, %d organisation strategies × %d task-force " % [s["seasons"], R.size(), L.size()]
			+ "strategies. Cells are the organisation's win rate.", "",
			"| boss \\ chief | " + " | ".join(L) + " |", "|---|" + "---|".repeat(L.size())]
		for i in R.size():
			lines.append("| %s | " % R[i] + " | ".join(m[i].map(func(x): return Py.f(100 * x, 0) + "%")) + " |")
		var mix := func(names: Array, w: Array) -> String:
			var parts := []
			for i in names.size():
				if w[i] > 0.01:
					parts.append("%s %s%%" % [names[i], Py.f(100 * w[i], 0)])
			return ", ".join(parts)
		lines += ["", "- **Equilibrium win rate (organisation): %s%%** (target 50 ± 5)" % Py.f(100 * v, 1),
			"- Equilibrium mix, organisation: " + mix.call(R, p),
			"- Equilibrium mix, task force: " + mix.call(L, q),
			"- Raw win rate over all pairings: %s for the organisation" % _pct(s["runner_win"]),
			"- Average season length: %s nights; decided before the last night: %s" % [Py.f(s["nights_mean"], 1), _pct(s["ended_early"])],
			"- Comebacks (half-time leader loses): %s; close finishes: %s" % [_pct(s["comeback_rate"]), _pct(s["close_finish"])],
			"", "How seasons end:", ""]
		for k in s["reasons"]:
			lines.append("- %s: %s" % [k, _pct(s["reasons"][k])])
		var dom := Strategic.dominance(m, R, L)
		lines += ["", "Dominance between archetypes (a bot archetype being beaten everywhere is fine; a *mechanic* "
			+ "nobody should use is not, see the next table): " + ("; ".join(dom) if dom else "none"), ""]
		for side in ["runner", "law"]:
			var av := Strategic.action_values(strat, side)
			if av:
				lines += ["What each %s order is worth " % ("organisation" if side == "runner" else "task-force")
					+ "(win rate when the random bot used it vs didn't):", "", "| order | effect | uses |", "|---|---|---|"]
				for a in Py.sorted_by(av.keys(), func(k): return -av[k][0]):
					lines.append("| %s | %s pts | %d |" % [a, _signed(av[a][0] * 100, 0), av[a][1]])
				lines.append("")
	if strat:
		var ends := Strategic.endings(strat)
		lines += ["Win conditions (target: each at least 8% of seasons):", "", "| ending | share |", "|---|---|"]
		for k in ends:
			lines.append("| %s | %s |" % [k, _pct(ends[k])])
		lines.append("")
	var rv = _load(results_dir, "rivals")
	if rv is Dictionary and not rv.is_empty():
		lines += ["## 4. The rival cartel (Los Cuervos)", "",
			"A third, AI-run outfit fights the organisation for the island's markets. Each night it flies its own "
			+ "loads in the zone it likes best (weighted by its turf and the pay, dodging a patrol it hears about). "
			+ "Its flights split the task force's attention; its busts are good press for the police. Where it owns "
			+ "the market the organisation's loads pay up to 40% less, and meeting it on the same route without a "
			+ "truce risks a hijack. The boss can hit it, buy a truce or sell its route to the police; the chief can "
			+ "send a gang unit after it.", "",
			"- Seasons with at least one hijack: %s; hijacks per season: %s" % [_pct(rv["hijack_seasons"]), Py.f(rv["hijacks_per_season"], 2)],
			"- Cartel planes busted per season: %s; cartel strength at the end: %s/100" % [Py.f(rv["rival_busts_per_season"], 2), Py.f(rv["end_strength"], 0)],
			""]
	var rz = _load(results_dir, "realism")
	if rz is Dictionary and not rz.is_empty():
		lines += ["## 5. The realism layer", "",
			"Weather and moon, pattern-of-life analysis, the canary trap and the rivals' tempers (entries 15-18 above), "
			+ "measured over the same seasons:", "",
			"- Storm nights per season: %s; seasons where a canary caught a leak: %s" % [Py.f(rz["storm_nights_per_season"], 2), _pct(rz["canary_catch_seasons"])],
			"- Truce betrayals per season, by temper: %s" % ", ".join((rz["betrayals_per_season_by_temper"] as Dictionary).keys().map(
				func(k): return "%s %s" % [k, Py.f(rz["betrayals_per_season_by_temper"][k], 3)])),
			"", "Betrayals by nights left in the season (backward induction: the end is when truces break):", "",
			"| nights left | " + " | ".join(range(10).map(func(i): return str(i))) + " |",
			"|---" + "|---".repeat(10) + "|",
			"| betrayals | " + " | ".join(range(10).map(func(i): return str(int(rz["betrayals_by_nights_left"].get(str(i), 0))))) + " |",
			"", "Route mixing against the analysts (entropy in bits; 1.585 = uniform over three routes):", "",
			"| organisation bot | route entropy | main run detected |", "|---|---|---|"]
		for pol in rz["route_entropy_by_runner"]:
			lines.append("| %s | %s | %s |" % [pol, Py.f(rz["route_entropy_by_runner"][pol], 2), _pct(rz["main_run_detected_by_runner"][pol])])
		lines.append("")
	var crew = _load(results_dir, "crew")
	if crew is Dictionary and not crew.is_empty():
		lines += ["## 6. What a co-pilot is worth", "",
			"The sea mission (airdrop to the go-fast, standard police) flown three ways: solo (autopilot on, the pilot "
			+ "goes aft and kicks, 4 s a bale), the AI co-pilot's habits (auto-kick over the mark, 2 s a bale) and a "
			+ "scripted human co-pilot through the command gate (calls the boat on the way in, kicks the load in one go). "
			+ "%d flights per crew." % int(crew["table"][0]["n"]), "",
			"| crew | bales kicked | bales delivered | s over the drop | flagged | busted | crashed | minutes |",
			"|---|---|---|---|---|---|---|---|"]
		for row in crew["table"]:
			lines.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % [row["crew"], _pct(row["kicked"]), _pct(row["delivered"]),
				Py.f(row["over_drop_s"], 0), _pct(row["flagged"]), _pct(row["busted"]), _pct(row["crashed"]), Py.f(row["minutes"], 1)])
		var ld: Dictionary = crew["loading_s"]
		lines += ["", "Ramp loading at a bush strip (no ground crew): %s s solo, %s s with a co-pilot." % [Py.f(ld["solo"], 1), Py.f(ld["copilot"], 1)], ""]
	var abl = _load(results_dir, "ablation")
	if abl:
		var base: float = abl["base"]
		lines += ["Ablations: equilibrium win rate with one mechanic switched off (baseline "
			+ "%s%%). Big swings mean the mechanic matters. Near zero means it's " % Py.f(100 * base, 1)
			+ "optional flavour.", "", "| without | organisation win | change |", "|---|---|---|"]
		var wo: Dictionary = abl["without"]
		for k in Py.sorted_by(wo.keys(), func(k): return -absf(wo[k] - base)):
			lines.append("| %s | %s%% | %s |" % [k, Py.f(100 * wo[k], 1), _signed(100 * (wo[k] - base), 1)])
		lines.append("")
	var live = _load(results_dir, "live")
	if live is Dictionary and not live.is_empty():
		lines += ["## 7. The live-play systems: the Family, the island, the Company", "",
			("`tools/live_balance.gd`: %d seeds x %s simulated hours per configuration, stepping those systems directly. " % [int(live["seeds"]), Py.f(live["hours"], 0)])
			+ "Flown runs stand in as $%s every %d min; the organisation's AI takes the Family's offers by their read and trades with the island " % [Py.money(int(live["stand_ins"]["run_pay"])), int(live["stand_ins"]["run_every_s"] / 60)]
			+ "when the odds are good; the task force's AI buys the customs tree, cracks down after a catch and files RICO when it can.", "",
			"| configuration | money p10 / p50 / p90 | task-force funds p50 | suspicion p50 |", "|---|---|---|---|"]
		for k in live["configs"]:
			var c: Dictionary = live["configs"][k]
			lines.append("| %s | $%s / $%s / $%s | $%s | %s |" % [k, Py.money(int(c["money"]["p10"])), Py.money(int(c["money"]["p50"])),
				Py.money(int(c["money"]["p90"])), Py.money(int(c["law_funds"]["p50"])), Py.f(c["suspicion"]["p50"], 0)])
		var al: Dictionary = live["configs"].get("all", {})
		if al.has("family"):
			var fm: Dictionary = al["family"]
			lines += ["", "The Family (all systems on): tribute paid p50 $%s; asked in %s of runs; a rat in %s; the Commission trial in %s; %s cons a run; respect ends at %s." % [
				Py.money(int(fm["tribute_paid"]["p50"])), _pct(fm["taxed_rate"]), _pct(fm["rat_rate"]), _pct(fm["trial_rate"]), Py.f(fm["cons"], 2), Py.f(fm["respect"], 0)]]
		if al.has("island"):
			var il: Dictionary = al["island"]
			lines += ["", "The island: %s shipments a run (p50); %s of mules and containers caught; closed by a purge %s of the time." % [
				Py.f(il["shipments"]["p50"], 0), _pct(il["catch_rate"]), _pct(il["closed_frac"])]]
		if al.has("payroll"):
			var py: Dictionary = al["payroll"]
			lines += ["", "The payroll (the organisation's AI hiring to its needs): %s workers on it at the end, $%s in wages over the run, %s lost (arrested or dead), %s flipped by the prosecutor, loyalty %s%%, a short payday in %s of runs." % [
				Py.f(py["crew"], 1), Py.money(int(py["paid"])), Py.f(py["lost"], 1), Py.f(py["flips"], 2), Py.f(100 * float(py["loyalty"]), 0), _pct(py["short_rate"])]]
		if al.has("agency"):
			var ag: Dictionary = al["agency"]
			lines += ["", "The Company: %s flights a run; $%s 'in the mail'; hung out to dry in %s of runs; exposed in %s." % [
				Py.f(ag["flights"], 1), Py.money(int(ag["withheld"])), _pct(ag["hangout_rate"]), _pct(ag["burned_rate"])]]
		var tr: Dictionary = live["configs"].get("trade", {}).get("trade", {})
		if not tr.is_empty():
			lines += ["", "The trade (career: grass first; the organisation's AI buying a load when the stash runs low, dealers on its corners, surplus to the best buyer): %s lb of grass and %s lb of cocaine sold, $%s made; the Colombians called after %s minutes; %s dealers on the corners at the end, %s bulk sales; %s left in the stash (worth $%s at the street)." % [
				Py.f(tr["sold_weed"], 0), Py.f(tr["sold_coke"], 0), Py.money(int(tr["earned"])), Py.f(tr["connected_min"], 0),
				Py.f(tr["dealers"], 1), Py.f(tr["bulk"], 1), "%s lb of cocaine and %s lb of grass" % [Py.f(tr["stock_coke"], 0), Py.f(tr["stock_weed"], 0)],
				Py.money(int(tr["stock_value"]))]]
		var lg: Dictionary = live["configs"].get("logistics", {})
		if lg.has("logistics"):
			var ll: Dictionary = lg["logistics"]
			var tr0: Dictionary = live["configs"].get("trade", {})
			lines += ["", "Logistics (the trade configuration with stock and cash in the stash houses, trucked by the organisation's AI): money p50 $%s against $%s without; $%s still out in the stashes, on the road and in the bags at the end; $%s of cash and %s lb of product lost to roadblocks, hijacks and raids a run." % [
				Py.money(int(lg["money"]["p50"])), Py.money(int(tr0.get("money", {}).get("p50", 0))), Py.money(int(ll["cash_out"])),
				Py.money(int(ll["lost_cash"])), Py.f(ll["lost_lb"], 0)]]
		var wr: Dictionary = live["configs"].get("war", {})
		if wr.has("war"):
			var w: Dictionary = wr["war"]
			lines += ["", "The street war (all systems plus the war, the organisation's AI commanding): money p50 $%s against $%s without; $%s recruiting, $%s on rifles, $%s upkeep a run; %s firefights a run, men lost %s of ours, %s of Los Cuervos', %s police, %s arrested (both outfits); %s squads of ours at the end against %s of Los Cuervos' and %s police; %s stash houses burned; suspicion p50 %s, p90 %s." % [
				Py.money(int(wr["money"]["p50"])), Py.money(int(live["configs"].get("all", {}).get("money", {}).get("p50", 0))),
				Py.money(int(w["recruit"])), Py.money(int(w["arms"])), Py.money(int(w["upkeep"])),
				Py.f(w.get("fights", 0), 1), Py.f(w.get("org_lost", 0), 1), Py.f(w.get("rival_lost", 0), 1), Py.f(w.get("police_lost", 0), 1), Py.f(w.get("org_arrested", 0), 1),
				Py.f(w["squads"], 1), Py.f(w["rival_squads"], 1), Py.f(w["police_squads"], 1), Py.f(w["burned"], 1),
				Py.f(wr["suspicion"]["p50"], 0), Py.f(wr["suspicion"]["p90"], 0)]]
		var air = _load(results_dir, "live-air")
		if air is Dictionary and air.get("configs", {}).has("air") and air["configs"].has("noair"):
			var ar: Dictionary = air["configs"]["air"]
			var a: Dictionary = ar["air"]
			lines += ["", "Air risk (all systems with logistics, the street war and the court; %d seeds x %s hours): money p50 $%s with each flight rolling the tactical sweep's odds, against $%s for the same systems at a fixed income. A run flew %s flights (paid $%s each when they counted), with %s busts, %s crashes, $%s in fines, $%s in repairs and %s minutes held by the court; the pilot stayed on the ground %s times with the police tipped off." % [
				int(air["seeds"]), Py.f(air["hours"], 0), Py.money(int(ar["money"]["p50"])), Py.money(int(air["configs"]["noair"]["money"]["p50"])),
				Py.f(a["flights"], 1), Py.money(int(a["pay"])), Py.f(a["busts"], 2), Py.f(a["crashes"], 2), Py.money(int(a["fines"])),
				Py.money(int(a["repairs"])), Py.f(a["held_min"], 0), Py.f(a["lay_low"], 1)]]
		var story = _load(results_dir, "live-story")
		if story is Dictionary and story.get("configs", {}).has("story"):
			var st: Dictionary = story["configs"]["story"]
			var reached := []
			for r in st["story"]["reached"]:
				if float(r["share"]) > 0.0 and int(r["chapter"]) > 1:
					var n := int(r["chapter"])
					reached.append("%s (%s at %s min)" % ["the end" if n > Story.CHAPTERS.size() else "ch%d %d" % [n, Story.CHAPTERS[n - 1][0]],
						_pct(r["share"]), Py.f(r["min_p50"], 0)])
			var worth := ""
			if st["story"].has("net_worth"):
				worth = ", net worth (cash, product and street money) p50 $%s" % Py.money(int(st["story"]["net_worth"]["p50"]))
			if st.has("air"):
				worth += "; with air risk: %s busts, %s crashes, $%s in fines and $%s in repairs a run" % [Py.f(st["air"]["busts"], 1),
					Py.f(st["air"]["crashes"], 1), Py.money(int(st["air"]["fines"])), Py.money(int(st["air"]["repairs"]))]
			if st.has("island"):
				worth += "; $%s a run spent on the island's product" % Py.money(int(float(st["island"]["spent"]) / maxf(1.0, float(story["seeds"]))))
			lines += ["", "The story (%d seeds x %s hours, the same stand-ins, chapters opening the systems): reached %s. Money p50 $%s at the end%s." % [
				int(story["seeds"]), Py.f(story["hours"], 0), ", ".join(reached), Py.money(int(st["money"]["p50"])), worth]]
		if al.has("market"):
			var mk: Dictionary = al["market"]
			lines += ["", "The street (all systems on): cocaine in town swung between x%s and x%s of its usual price in a run (means); guns averaged x%s; the worst broken network reached %s; the Company flew %s lots of cocaine north and bought %s lots of guns." % [
				Py.f(mk["coke_lo"], 2), Py.f(mk["coke_hi"], 2), Py.f(mk["guns"], 2), _pct(mk["disruption"]), Py.f(mk["coke_lots"], 1), Py.f(mk["gun_lots"], 1)]]
			if live["configs"].has("control") and live["configs"]["control"].has("market"):
				var ck: Dictionary = live["configs"]["control"]["market"]
				lines += ["Without the Company and the rest (control): cocaine x%s-x%s, guns x%s." % [Py.f(ck["coke_lo"], 2), Py.f(ck["coke_hi"], 2), Py.f(ck["guns"], 2)]]
		lines += ["", "Customs odds and expected return per dollar for one load:", "",
			"| case | mule caught | mule ROI | container found | container ROI |", "|---|---|---|---|---|"]
		for r in live["odds"]:
			lines.append("| %s | %s | %s | %s | %s |" % [r["case"], _pct(r["mule_p"]), Py.f(r["mule_roi"], 2), _pct(r["ship_p"]), Py.f(r["ship_roi"], 2)])
		lines.append("")
	lines += ["## Known limits", "",
		"- The live-play simulator (section 7) steps the street war with a stand-in for the police's "
		+ "cooling of the case (a tenth of the live rate) and no police aircraft: the war's suspicion "
		+ "numbers are indicative, its money numbers are the point.",
		"- The tactical numbers come from one bot that flies well but plays simply: it follows valleys "
		+ "and ducks when it sees police, but it doesn't read the police radio or bluff. Humans will do "
		+ "better on the runner side, so the real task force should be a little stronger than these "
		+ "numbers suggest.",
		"- The season simulator rolls nights from calibrated probabilities. It captures the economy and "
		+ "the information war, not flying skill.",
		"- Sample sizes: tactical cells have 10-30 flights each. Anything under about 10 points of "
		+ "difference is noise.",
		"- Recruit is nearly worthless to a random bot (+2 pts) but the single biggest ablation at "
		+ "equilibrium (about +20 pts even after the cost/odds were scaled per informant): most of its "
		+ "value is 'have one informant at all' versus 'have none', which no per-informant tuning "
		+ "touches. If this reads as too strong in playtests, the next lever is the tip mechanic the "
		+ "first informant grants, not the recruiting cost.",
		"- The upgrade trees, the city map's stash runs and the markets aren't in the season model (entry 23). "
		+ "They're built to be symmetric, but only playtests will say whether, say, the mole or the jammer van "
		+ "is priced right. The tactical sweep and the seasons run on the classic island; the city map shares "
		+ "the zones and rules, not the calibration.",
		"- The live-play simulator (section 7) doesn't fly. In most configurations runs are a fixed income; the air and story "
		+ "configurations roll the tactical sweep's odds per flight (AirRisk, entry 31), with the pilot flying the tactic that "
		+ "did best against the police's posture. That's a pilot who has learned the game, flying as well as the bot: a "
		+ "human's skill, bluffing and reading the police radio aren't modelled. What the Family's services save (a boarding "
		+ "slowed) isn't counted. Read it for the economies of those systems, not for who wins."]
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	return out_path
