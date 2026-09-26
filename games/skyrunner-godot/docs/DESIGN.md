# Skyrunner design: runners, kickers and the task force

> This is the design document of the Godot game (the one game). It began life with the original
> Python prototype, which is now kept only as the reference that generated the frozen parity
> fixtures in `tests/fixtures/`; nothing in the Godot build needs it. Sections 10-12 cover what
> the Godot build added.

This is the plan for taking Skyrunner from a single-player bush-flying game to an
asymmetric **traffickers vs. law enforcement** game. It supports solo play against AI,
co-op crews, and team-vs-team multiplayer, and it follows a campaign that gets harder
year by year.

Status legend: **[done]** in the code now · **[phase 3+]** planned, see *Roadmap*.

---

## 1. Pillars

1. **The aircraft is the puzzle.** Weight, balance and fuel are one budget: every pound of
   fuel is a pound of cargo you can't carry. JSBSim flies the result honestly.
2. **Information is the weapon.** Neither side sees the truth. Traffickers work from radar
   warnings, scanner chatter and spotter calls. Police work from radar tracks, tips and
   direction-finding fixes. Most of the game is about controlling what the other side knows.
3. **Every tool has a counter.** Each gadget exists together with the thing that beats it
   (see the matrix in §4). Balance comes from the pairs, not from raw stats.
4. **Complexity arrives one year at a time.** The campaign adds one system per chapter, so
   by 1986 you juggle all of them, but you learned each one alone.

## 2. Modes

| Mode | Humans | AI fills | Status |
|---|---|---|---|
| **Solo runner** | Pilot | Police, optional AI co-pilot | [done] |
| **Solo task force** | Controller | AI smuggler flights + boats | [done] |
| **Co-op crew** | Pilot + co-pilot (+ spotter) | Police | [done] (co-pilot and spotter use the station client) |
| **Versus** | Runner crew vs. controller (+ interceptor pilot) | Empty roles | [done]; controller and spotter use the station client; interceptor pilot is [phase 3+] |
| **Campaign** | Solo or co-op | Scripted threats per chapter | [done]: chapters 1–4 playable, 5–8 scripted in this doc |

Any seat without a human is filled by AI, so the same match can be played by 1 to 6 people.

## 3. Roles

### Runner side

| Role | Job | Sees | Status |
|---|---|---|---|
| **Pilot** | Flies (JSBSim). Transponder, flaps, autopilot. | Out the window, HUD, radar-detector light | [done] |
| **Co-pilot / kicker** | Loads the aircraft (twice the loading speed), pumps ferry fuel, kicks bales out over drop zones, runs the radio scanner and calls the boat | Tactical map: own aircraft, boat, bales, intercepted police traffic, radar-warning status | [done] (station client + AI fallback) |
| **Spotter** | Watches one airstrip from the ground. Reports police units and roadblocks near it. Can relocate (takes time). | Units within 5 km of the watched strip, reported with a delay | [done] (AI-driven reports; human uses the station client) |
| **Boat captain** | Go-fast boat. Waits at the rendezvous, fishes bales out of the water, runs for the cove. | Surface picture around the boat | [done] AI; human-driven boat [phase 3+] |
| **Fixer** | Books jobs, hires spotters, buys gear, manages heat and money between flights | Job boards, black market | [phase 3+] (the pilot does this now) |
| **Mechanic** | Field refuelling from caches, quick repairs at bush strips | | [phase 3+] |

### Law side

| Role | Job | Sees | Status |
|---|---|---|---|
| **Controller** (radar/intel desk) | Reads the fused radar picture, classifies tracks, dispatches helicopters, interceptors and cutters, sets radio encryption, requests the aerostat | Radar tracks (with position noise, no identity for non-squawking targets), tips, DF bearings. Never the true runner position. | [done] (station client + AI fallback) |
| **Interceptor pilot** | Flies the chase aircraft and makes the visual ID | Out the window, its own radar | AI [done]; human pilot [phase 3+] |
| **Coast Guard cutter** | Hunts boats and seizes floating bales | Surface radar | [done] AI; human [phase 3+] |
| **Analyst** | Works the informant network, fuel-purchase records and tail numbers | Tip feed | [phase 3+] (folded into Controller now) |
| **Undercover agent** | Plants a tracking beacon on a runner aircraft on the ground | | [phase 3+] |

### Hidden role (versus, [phase 3+])
**The informant.** One runner-side player may secretly be working for the task force. They
score if the crew gets busted and lose if they're caught leaking, so they have to sabotage
quietly (a bad load plan, "forgetting" to pump fuel, calling the boat on an open channel).
This is the social-deduction layer that gives crews a reason to watch each other.

## 4. Gadgets and counters

| Runner tool | What it does | Law counter | Counter to the counter |
|---|---|---|---|
| **Flying low** | Below the radar floor (≈45 m AGL + 9 m per km of range), and behind terrain, primary radar can't see you | **Aerostat radar** (tethered balloon at 2.5 km altitude: huge line of sight, low floor) | Stay out of its footprint; it's winched down in high wind [phase 3+] |
| **Transponder off** | No secondary return, so no identity | An unidentified primary track builds suspicion fast | Keep squawking to look like legit traffic. But turning it *off* while tracked ("squawk lost") is a big red flag. |
| **Transponder on** | You look like a normal charter | You're tracked the whole time you're in coverage; an informant tip names your tail | Only squawk on legit legs |
| **Radar detector** ("fuzzbuster") | Warns when a radar illuminates you, and whether you're above its detection floor | No direct counter (passive) | – |
| **Radio scanner** | Hears police dispatch in plain voice: unit, base, heading | **Encrypted radio** (controller toggle): dispatch becomes garbled static | Encryption slows coordination (dispatch delay +8 s) |
| **Boat radio calls** | Needed to bring the boat to the drop point | **Direction finding**: every transmission gives the task force a bearing, and two stations give a fix | Keep calls short, call from a different spot than the drop, or pre-plan the rendezvous with no call (the boat waits longer, and waiting boats get spotted) |
| **Ground spotters** | Early warning of police at your destination | **Informants**: a hired spotter may leak your destination (a tip with a 3 km circle) | Pay more for trusted spotters [phase 3+], vary destinations |
| **Ferry tanks** | Long runs from offshore, no fuel stops | **Fuel-purchase tracking**: buying ferry fuel at a police field raises a tip chance | Fuel caches at bush strips (fly the drums in first) |
| **Airdrops to boats** | Never land with the goods | **Coast Guard cutters** and the "drop pattern" classifier (a slow, low track circling over water) | Drop fast, drop in the dark [phase 3+], decoy boats [phase 3+] |
| **Decoy flights** [phase 3+] | A clean aircraft flies the obvious route | Controller has limited units: committing to the decoy is the cost | – |

**Resource limits keep the controller honest.** The task force starts with 1 helicopter,
2 interceptors and 1 cutter, each with a launch delay and a fuel endurance. They're
refuelled and recommitted at a base. The runner crew is always cheaper to field
than the full response, which is how the side with less information stays viable.

## 5. Systems

### 5.1 Fuel is weight [done]
- JSBSim burns fuel from real tank locations, so the CG moves during the flight.
- The HUD shows endurance and still-air range from the live fuel flow.
- **Ferry bladder tanks** are cargo items (25 lb empty + fuel) that take up a cabin station.
  Their fuel only reaches the engine if someone pumps it into the wing tanks. The co-pilot
  pumps 60 lb/min; solo, the pilot can run the electric pump at 25 lb/min.
- Buying fuel beyond wing-tank capacity at a police field has a chance to produce a tip.

### 5.2 Loading takes time [done]
- Every item moved on the ground takes `4 s + 0.02 s/lb` of crew time. Crew = pilot, plus
  co-pilot, plus the ramp crew at hubs. Loading at a bush strip while the spotter reports
  police inbound is the tension beat.

### 5.3 Airdrops [done]
- Droppable items (bales) are kicked out of the door by a crew member: 2 s per bale for the
  co-pilot, 4 s for the pilot on autopilot. Above 130 kt the door can't be used.
- Each bale is a ballistic object with drag (terminal velocity ≈ 35 m/s) that inherits the
  aircraft's velocity. If it lands in the water, it floats and drifts. If it lands on land,
  it's lost (ground drop zones with a pickup truck are [phase 3+]).
- The boat collects bales within 40 m (5 s each), then runs for the cove. The job pays per
  bale delivered to the cove.
- **Autopilot** (wing leveller + altitude hold) exists so a solo pilot can go aft and kick.

### 5.4 Sensors and the track picture [done]
- Every emitter and target produces a `Signature`: position, height above ground, speed,
  transponder state, recent radio transmissions.
- Sensors (ground radar, aerostat, unit eyeball/FLIR, direction-finding stations) turn
  signatures into **tracks** with position noise and an age.
- AI police steer to the **last known position**, not the truth. Break contact and they
  search the last place they saw you.

### 5.5 Radio [done]
- One message log per channel (`police`, `runner`). Police dispatch is plain voice
  unless encrypted. The runner scanner intercepts plain police messages. Runner
  transmissions can be heard by DF stations.

## 6. Storyline (campaign)

**Setting.** Palmetto Cay, a fictional island between the Florida Keys and the Bahamas,
1979–1986. The tone draws on the era's documentaries and dramas about the South Florida
smuggling boom and the Miami-based task forces sent to stop it (the *Cocaine Cowboys*
documentaries, *Miami Vice*, *American Made*, *Blow*, *Air America*, *Narcos*). All characters
and events here are original.

**Protagonist.** *Jack "Dusty" Callahan*, a bush pilot who owes the bank for a tired
Cessna 172. His sister *Rosa* runs the mail contract and is your first co-pilot. The fixer is
*Manny Arce*, a charming boat dealer from Smuggler's Cove. The antagonist on the law side is
*Special Agent Evelyn Hart*, who takes over the island's interdiction desk in 1983.

| Ch. | Year | Title | Introduces | Objectives | Status |
|---|---|---|---|---|---|
| 1 | 1979 | **Mail Run** | Flying, W&B, short strips | Earn $5,000 legally, land at Eagle's Nest | [done] |
| 2 | 1980 | **A Favor for Manny** | Contraband, radar floors, flying low | Deliver one hot cargo without reaching wanted ★ | [done] |
| 3 | 1981 | **Kickers** | Co-pilot, airdrops, boat rendezvous, radio calls | Drop 4 bales to the *Lady Luck*, 3 must reach the cove | [done] |
| 4 | 1982 | **Long Legs** | Ferry tanks, fuel planning, offshore entry, fuel caches | Fly in from the south entry point with a ferry tank and make a drop | [done] |
| 5 | 1983 | **The Balloon** | Aerostat radar goes up, radar detector, spotters | Complete a run inside aerostat coverage without being tracked for more than 60 s | [phase 3+] |
| 6 | 1984 | **Blue Water** | Coast Guard cutters, encrypted police radio, DF | Make two drops in one night with encryption active | [phase 3+] |
| 7 | 1985 | **The Leak** | Informants, decoy flights, hidden-role versus | Find the leak (one of three spotters) before the big run | [phase 3+] |
| 8 | 1986 | **Last Run / Flip** | Everything | Branch: pull off the biggest run of your life, **or** take Hart's deal and play the finale on the law side | [phase 3+] |

**The task-force campaign** (law side, 1983–1986) replays the same years from Hart's desk:
building the radar net, getting encryption budget approved, turning Callahan's spotters. In
chapter 8 the two campaigns meet: the runner's "Flip" branch hands you Hart's desk for the
final interdiction.

**Difficulty ramp.** Each chapter raises the threat level: 1 radar site in 1979, plus
interceptors in 1981, the aerostat and cutters in 1983, encryption and DF in 1984, informants
in 1985. It also removes a crutch, such as a free loadmaster or a daytime-only schedule.

## 7. Multiplayer architecture

```
 Pilot's game (3D, Godot 4) ─────────────┐   authoritative Session (JSBSim + AI + rules), 60 Hz
   └─ listen server (HostServer, TCP) ───┤   snapshots 15 Hz, filtered per role (fog of war)
                                         │
 Station clients (2D tactical UI) ◄──────┘   TCP, newline-delimited JSON
   co-pilot · spotter · controller           commands -> Session.command(role, name, args)
```

- **Authoritative host.** The pilot's machine runs the only simulation. Remote players send
  *commands* (validated against a per-role permission table) and receive *snapshots* built
  for their side only. A controller snapshot contains radar tracks, never the true runner
  position.
- **Why TCP + JSON now:** zero dependencies, trivial to debug, and fine at 15 Hz on a LAN or a
  decent WAN. Station UIs are map views, so a 100 ms delay is invisible there.
- **Phase 3:** a remote *pilot* (interceptor or second runner) needs UDP with client-side
  prediction of their own JSBSim instance (ENet through Godot's MultiplayerPeer), with the
  server reconciling. Snapshots already carry sequence numbers for this.
- **Dedicated server:** `Session` has no rendering dependency, so a headless server is the same
  code minus the window (`godot --headless --script res://scripts/net/dedicated.gd`).

## 8. Balance notes and tuning knobs

| Knob | Default | Effect |
|---|---|---|
| Radar floor | 45 m + 9 m/km | Lower = police stronger; tune per chapter |
| Aerostat floor | 20 m + 3 m/km | Makes flying low necessary but not sufficient |
| Suspicion rate | 8–33 %/s in coverage | How long a runner can clip radar coverage |
| Bust time | ~4.5 s within 350 m | How close an interceptor must fly formation |
| Encryption dispatch delay | +8 s | Cost of denying the scanner |
| Spotter leak chance | 15% per hired spotter per job | Informant pressure |
| Ferry-fuel tip chance | 25% at police fields | Pushes runners to caches |

Balance target for versus: a competent crew completes about 55% of runs against a competent
controller. The AI controller should land at about 70% for new players.

## 9. Roadmap

1. **Phase 1 [done]:** single-player core. JSBSim W&B, tight strips, jobs, radar/wanted, AI police.
2. **Phase 2 [done] (framework):** roles and permissions, command API, event bus, sensors and
   tracks, radio/scanner/DF, spotters and informants, transponder, radar detector, aerostat, ferry
   tanks, loading time, autopilot, airdrops, boats and cutters, AI smuggler, controller mode,
   campaign engine with chapters 1–4, listen server + station client, role-filtered snapshots.
3. **Phase 3 [done] (seats, HQs, bots, balance):** remote 3D seats (co-pilot in the right seat; police
   pilot flying a heli/interceptor with the AI units' envelope, fog-of-war visuals) over TCP with
   interpolation; boss and chief HQ seats and a season of nights (`scripts/sim/hq.gd`, `nights.gd`); decoy
   flights and contract crews; rule layers scaled by player count (`scripts/sim/layers.gd`); a pilot bot flying
   JSBSim, HQ bots, and feasibility / tactical / strategic simulators that drove the balance changes
   in [BALANCE.md](BALANCE.md); textured graphics with low/medium/high presets. Design reasoning:
   [MULTIPLAYER.md](MULTIPLAYER.md).
4. **Phase 4 (depth):** UDP snapshots with prediction, human-driven boats, night and FLIR, wind,
   AEW patrol aircraft, fixer/mechanic roles, the hidden informant, planted beacons, persistent
   career across chapters, chapters 5–8 and the task-force campaign, smarter runner bots.
5. **Phase 5 (content):** bigger map (mainland coast + island chain), more aircraft (JSBSim
   `L410`, `C130`), audio, real 3D models, matchmaking and a dedicated server.

## 10. What the Godot build added

- **Engine.** Godot 4.4 with JSBSim 1.3.1 in a C++ GDExtension (`native/`), the simulation in GDScript
  (`scripts/sim/`), bit-exact with the Python reference where the fixtures say so ([PORTING.md](PORTING.md)).
- **Realism layer.** Weather and moon, pattern of life, canary traps, rival tempers, spare-helicopter
  patrols, nerves ([BALANCE.md](BALANCE.md) entries 14-19).
- **Radar and radio** that behave like the real thing (`sensors.gd`, `comms.gd`): radar horizon, clutter,
  MTI, scan rates, Pd, trails, Mode C, squawk codes and coverage; VHF line of sight, channels,
  push-to-talk length, least-squares DF with an error ellipse, jamming.
- **Upgrade trees** for both sides (`upgrades.gd`), paid from runner cash and task-force funds.
- **Costa Brava**, the city coast and default map (`map_city.gd`): the port city of San Telmo, estuary,
  farm plain, jungle range, quarry, cays; stash houses (`stashes.gd`) with trucked deliveries and raids.
- **Markets** (`economy.gd`): prices per good per market, moved by rivals, police, seizures, gluts,
  fuel, weather and the news.

## 11. The ground war, gun running and arsenals

- **Arsenals** (`arsenal.gd`): the organisation, the task force and Los Cuervos each hold weapons by
  tier (pistols, rifles, machine guns, RPGs) and ammunition. Gun runs bring crates in; on delivery you
  **sell** them at the street price or **stock** your own arsenal. Everything the police seize
  (busted loads, trucks, raided stashes, lost firefights) goes into *their* arsenal and arms their
  patrols.
- **Squads** (`ground.gd`): gang soldiers, Los Cuervos' crews and police patrols, on foot, in cars and
  in trucks, driving the city's roads (`road_graph.gd`). They guard stashes, escort trucks, set
  checkpoints, patrol and raid. Where they meet, a firefight is resolved with Lanchester's square law
  on each side's weapons, cover and morale. Squad-minutes in a zone move the turf, and turf moves the
  markets and the season.
- **Commanders.** Each faction's squads are run by an AI commander by default; a human
  **lieutenant** (runner side) or **patrol commander** (law side) can take over at any time, and the
  boss and chief set the budgets.
- **On foot.** Out of the aircraft you can draw a weapon from your side's arsenal and shoot it out
  with squads near you, who are simulated man by man inside a 300 m bubble.

## 12. Seats: every role AI until a human takes it

Every role in every mode exists from the start and is run by the AI. Humans join mid-game and
claim any free seat from the role picker; leaving (or dropping for more than 30 s) hands it back to
the AI. The host's `Seats` table is the single place this happens. See [MULTIPLAYER.md](MULTIPLAYER.md)
for the protocol, the roster and chat.
