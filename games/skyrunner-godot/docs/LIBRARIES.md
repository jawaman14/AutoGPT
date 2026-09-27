# Open-source Godot libraries: what fits Skyrunner

A survey of free and libre Godot 4 add-ons and projects on GitHub (September 2026), judged against
this game's constraints:

- The simulation is plain GDScript that must stay bit-identical to the archived Python replays
  (the parity tests). Anything that replaces sim code has to earn that risk.
- Screenshots, videos and CI run on the compatibility renderer (llvmpipe, no GPU), so compute
  shaders and Forward+-only effects can only be an optional extra.
- Everything must be MIT, CC0 or similar, vendored with its licence.

## Adopted

| Library | Licence | What it does here |
|---|---|---|
| [Debug Menu](https://github.com/godot-extended-libraries/godot-debug-menu) (Calinou) | MIT | F6 in the 3D view: FPS, frame-time graphs, CPU/GPU times, hardware. Vendored in `addons/debug_menu/` without its editor plugin; loaded on demand (its own F3 binding would clash with the AI pilot) and skipped headless (its hardware-query thread never returns without a GPU). Useful for checking the cost of the animated characters and the island. |
| [Dialogue Manager](https://github.com/nathanhoad/godot_dialogue_manager) (Nathan Hoad), v3.10.5 | MIT | The conversations with the Family (Sal Moretti) and the General's aide (Captain Ibarra), written as scripts in `dialogue/*.dialogue`. Only the runtime is vendored (`addons/dialogue_manager/`, pinned in `UPSTREAM.txt`); v3.x is the line for Godot 4.4 (v4 needs 4.6). No plugin, autoload or import step: `scripts/game/talk.gd` instances the manager and compiles the scripts from text. The scripts act through the seat's permission-checked commands, so they work from a remote seat too. Our own balloon (`scripts/ui/talk_balloon.gd`) draws them in the game's style. |
| [Input Helper](https://github.com/nathanhoad/godot_input_helper) (Nathan Hoad), v4.7.0 | MIT | Rebinding the flight keys and gamepad buttons (F8), and naming a button for the pad in use (Xbox, PlayStation, Switch, Steam Deck). The runtime only, instanced on demand (`scripts/game/controls_config.gd`). We save the events ourselves: its text format turns physical keys into layout keycodes and pins joypad buttons to pad 0. |
| [SimpleGodotCRTShader](https://github.com/henriquelalves/SimpleGodotCRTShader) (Henrique Lacreta Alves) | MIT | The F9 VHS filter, with gentler uniforms than the demo's (`scripts/render/screen_filter.gd`). |
| [GATO screen filters](https://github.com/Nokorpo/gato-godot-accessibility-toolkit) (Iseltec) | MPL-2.0 | Its colour-blindness matrices: the F9 simulations and `test_accessibility`, which found the neon palette failing and checks the colour-safe one. The shader is vendored unmodified, with its licence (MPL is per file). |
| [Kenney UI Audio](https://github.com/Calinou/kenney-ui-audio) (via Calinou) | CC0 | The UI's clicks (a conversation's answer, toggles) in `assets/audio/kenney_ui/`. |
| [Kenney's 3D kits](https://github.com/shorepine/kenney) | CC0 | The people, cars, guns, boats and palms (`assets/models/kenney/`, see the README). |
| [JSBSim](https://github.com/JSBSim-Team/jsbsim) | LGPL-2.1 | The flight model, through our own GDExtension (already in use). |

## Worth adopting next

| Library | Licence | Where it would go | Cost / risk |
|---|---|---|---|
| Dialogue Manager, further | MIT | Adopted (above) for the Family and the General; the Company's contact and a defector's plea are the next scripts to write. | Low: a new `.dialogue` file and a key. |
| [Phantom Camera](https://github.com/ramokz/phantom-camera) | MIT | The demo tours and cinematic shots (follow, framing, tweened cuts) instead of hand-lerped cameras in `tools/*_tour.gd`. | Low: tools only. |
| [netfox](https://github.com/foxssake/netfox) | MIT | Lag compensation and client prediction for the remote pilot seat, or for on-foot combat between human players. | High: our protocol v3 is authoritative and snapshot-based, so this would be a partial adoption at most. |
| [LimboAI](https://github.com/limbonaut/limboai) or [Beehave](https://github.com/bitbrain/beehave) | MIT | Behaviour trees for new AI that isn't in the parity replays (the Family's and the island's actors, squad tactics). | Medium: the current utility and state code is tested and deterministic; a behaviour tree must keep its own RNG streams. |

## The free lists, second pass (September 2026)

Went through [awesome-godot](https://github.com/godotengine/awesome-godot) section by section and
[awesome-cc0](https://github.com/madjin/awesome-cc0) for free assets. The gap they exposed was
**sound**: the game had none but a synthesized heartbeat.
- The lists' CC0 audio is almost all on websites (Freesound, OpenGameArt, Free Music Archive), not
  on GitHub, and this build's network can't reach those sites.
- The one GitHub-hosted CC0 pack, Kenney's UI audio, is now in.
- Everything else is synthesized in `scripts/game/sound.gd`, which needs no licence:
  - the engine and propeller, pitched by JSBSim's RPM;
  - the wind, the stall horn and the tyres;
  - the radio's squelch;
  - gunfire at the ground war's fights and from your own gun;
  - police helicopters' rotors, cruisers' sirens and the go-fasts' outboards;
  - surf, rain and thunder;
  - an 80s synth station (F7).

  Listen to samples in `docs/audio/`.

| From the lists | Licence | Verdict |
|---|---|---|
| [Event Audio](https://github.com/bbbscarter/event-audio-godot) | MIT | Fire-and-forget audio events. Our soundscape is small enough to own; worth it if the sound grows to hundreds of cues. |
| [Wwise](https://github.com/alessandrofama/wwise-godot-integration), [FMOD GD4](https://github.com/summertimejordi/fmod_gd4) | proprietary middleware | Not a fit: licensing and a sound-design toolchain for a synthesized soundscape. |
| [Input Helper](https://github.com/nathanhoad/godot_input_helper) | MIT | Adopted in the third pass (above). |
| [Virtual Joystick](https://github.com/MarcoFazioRandom/Virtual-Joystick-Godot) | MIT | Only if a touch build happens. |
| [NobodyWho](https://github.com/nobodywho-ooo/nobodywho) | EUPL | Local LLMs for NPC dialogue: tempting for Sal, Ibarra and the lawyers, but it needs model files of gigabytes and a GPU. An opt-in experiment at most, next to the written dialogue. |
| [Dialogic](https://github.com/dialogic-godot/dialogic) | MIT | Covered: Dialogue Manager does the conversations. |
| [Juicee](https://github.com/Kelpekk/Juicee) | MIT | Game-feel effects (shake, hit-stop): small wins for gunplay; the graph editor is more than we need. |
| [Godot Doctor](https://github.com/codevogel/godot_doctor), [Signal Lens](https://github.com/yannlemos/signal-lens) | MIT | Editor-side debugging; the headless test suite covers what they'd catch for us. |
| [TerraBrush](https://github.com/spimort/TerraBrush), [ProtonGraph](https://github.com/protongraph/protongraph) | MIT | Editor terrain and procedural graphs: the terrain is native and read by the sim (as with Terrain3D). |
| [VitaVehicle](https://jreo.itch.io/rcp4) | - | Raycast cars: our cars are sim-driven squads on a road graph, not player-driven. |

## The lists, third pass (September 2026)

I went back over [awesome-godot](https://github.com/godotengine/awesome-godot) and, beyond it, the official
[demo projects](https://github.com/godotengine/godot-demo-projects), the
[GATO accessibility toolkit](https://github.com/Nokorpo/gato-godot-accessibility-toolkit) and the KayKit CC0 kits.
Only GitHub is reachable from the build box, so the Asset Library, Godot Shaders, Poly Haven, OpenGameArt and
Freesound were out of reach. This pass exposed two gaps:

- **Controls.** The joystick code assumed one gamepad: left stick for the yoke, right stick X for the rudder, triggers for the throttle.
  - Real sim hardware is a yoke with its own throttle axis, rudder pedals on a second USB device, and toe brakes.
  - Input Helper is built for gamepads and has no axis binding per device, so `scripts/game/flight_axes.gd` does that part:
    - you bind a control by moving it;
    - devices are matched by name;
    - invert, deadzone and expo per control.

  Input Helper does the keys and buttons.
- **Colour.** GATO's colour-blindness matrices, applied to the game's colours and measured as CIE76 ΔE:

| Colours | Worst pair | ΔE | Verdict |
|---|---|---|---|
| Factions on the map (org / rival / police) | org vs rival, tritanopia | 39 | fine |
| Faction suits | org vs police, tritanopia | 61 | fine |
| Neon status colours | GREEN vs PINK, protanopia | **4** | fails. So do RED vs AMBER under deuteranopia (15) and AMBER vs PINK under tritanopia (11). |
| Colour-safe status colours | GREEN vs CYAN, tritanopia | 22 | passes (≥ 20) |

The simulation shader only shows the problem; the colour-safe palette is the fix for players.

| Also looked at | Licence | Verdict |
|---|---|---|
| [GATO text-to-speech](https://github.com/Nokorpo/gato-godot-accessibility-toolkit) | MPL-2.0 | Next for accessibility: reading the conversations and menus aloud through the OS voice. |
| [GodotShaderWarmup](https://github.com/Koisuji02/GodotShaderWarmup) | MIT | A GDExtension plus manifests to pre-compile shaders. Only if the animated Kenney characters or the island stutter on first sight. Measure with F6 first. |
| [Phantom Camera](https://github.com/ramokz/phantom-camera), [Shaker](https://github.com/Eneskp3441/Shaker) | MIT | Tour cameras; screen shake for gunfire and turbulence. Small, later. |
| [Maaack's Game/Menus Template](https://github.com/Maaack/Godot-Game-Template) | MIT | We have our own lobby and menus. |
| [GdUnit4](https://github.com/MikeSchulze/gdUnit4), [Vest](https://github.com/foxssake/vest) | MIT | We have our own runner. |
| [gdtoolkit](https://github.com/Scony/godot-gdscript-toolkit) | MIT | gdlint/gdformat in CI: worth a try, but noisy on a codebase this size until it's configured. |
| [Godot SQLite](https://github.com/2shady4u/godot-sqlite), [Talo](https://github.com/TaloDev/godot) | MIT | Saves are JSON and the game is self-hosted; nothing to gain. |
| [License Manager](https://kenyoni-software.github.io/godot-addons/addons/licenses) | MIT | Could generate an in-game credits screen from the licences we already vendor. |
| [KayKit City Builder Bits](https://github.com/KayKit-Game-Assets) | CC0 | Streetlights and traffic lights for the city. Optional art. |
| [Simplified Flight Simulation](https://github.com/fbcosentino/godot-simplified-flightsim) | MIT | We fly JSBSim. |

## Looked at, not a fit

| Library | Why not |
|---|---|
| [godot4-oceanfft](https://github.com/tessarakkt/godot4-oceanfft) (FFT ocean, buoyancy) | Compute shaders: Forward+ only. It could be an optional "ultra" water later; boats in the sim are kinematic anyway. |
| [Gerstner waves and buoyancy](https://github.com/stvgale/Gerstner-Waves-Buoyancy-Effects-Godot-4), [Godot-Ocean-Shader](https://github.com/immaculate-lift-studio/Godot-Ocean-Shader) | Our ocean shader already does Gerstner-style waves; nothing to gain. |
| [Terrain3D](https://github.com/TokisanGames/Terrain3D) | The terrain is generated natively and read by the sim (radar line-of-sight, landings), so it can't be swapped for an editor terrain. |
| [GodotJSBSim](https://github.com/lewhfree/GodotJSBSim), [jsbgodot](https://github.com/chunky/jsbgodot) | We already bind JSBSim ourselves, with the exact API the sim needs. |
| [GUT](https://github.com/bitwes/Gut) | We have our own headless test runner (`tools/test.sh`, 320+ tests); moving buys nothing. |

Sources: [awesome-godot](https://github.com/godotengine/awesome-godot) (the curated list), and each project's repository above.
