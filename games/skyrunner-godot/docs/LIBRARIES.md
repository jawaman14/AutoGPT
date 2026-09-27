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
| [Kenney Particle Pack](https://github.com/shorepine/kenney) | CC0 | Fire, flame, smoke, spark, splash-ring and dirt sprites (`assets/fx/kenney_particles/`, 128 px) for `scripts/render/fx.gd`: burning wrecks, smoking stash houses, RPG blasts, splashes when bales hit the sea. |
| [KayKit City Builder Bits](https://github.com/KayKit-Game-Assets/KayKit-City-Builder-Bits-1.0) (Kay Lousberg) | CC0 | The street furniture in town: lamp posts with their arms over the road (the glowing heads light up at night), traffic lights at the junction, hydrants, benches, dumpsters and bins (`assets/models/kaykit/city/`). |
| [Jolt Physics](https://github.com/godotengine/godot) (built into Godot since 4.4) | MIT | The 3D physics engine (`physics/3d/physics_engine`). All 386 tests pass on it; only the on-foot colliders and the blast debris use physics. The simulation never does. |
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
| [GATO text-to-speech](https://github.com/Nokorpo/gato-godot-accessibility-toolkit) | MPL-2.0 | Done in the fourth pass. Its plugin wraps Godot's own `DisplayServer.tts_*`, so `scripts/game/speech.gd` calls that directly: conversations and radio calls, read aloud (F8). |
| [GodotShaderWarmup](https://github.com/Koisuji02/GodotShaderWarmup) | MIT | Still not adopted. It's a native binary per platform, and first-sight stutter can't be measured on this GPU-less build box. Godot has had a built-in shader baker that does the same job since 4.5; the project is on 4.7 with it on in the export presets, so measure with F6 before adding anything. |
| [Phantom Camera](https://github.com/ramokz/phantom-camera), [Shaker](https://github.com/Eneskp3441/Shaker) | MIT | Tour cameras; screen shake for gunfire and turbulence. Small, later. |
| [Maaack's Game/Menus Template](https://github.com/Maaack/Godot-Game-Template) | MIT | We have our own lobby and menus. |
| [GdUnit4](https://github.com/MikeSchulze/gdUnit4), [Vest](https://github.com/foxssake/vest) | MIT | We have our own runner. |
| [gdtoolkit](https://github.com/Scony/godot-gdscript-toolkit) | MIT | gdlint/gdformat in CI: worth a try, but noisy on a codebase this size until it's configured. |
| [Godot SQLite](https://github.com/2shady4u/godot-sqlite), [Talo](https://github.com/TaloDev/godot) | MIT | Saves are JSON and the game is self-hosted; nothing to gain. |
| [License Manager](https://kenyoni-software.github.io/godot-addons/addons/licenses) | MIT | Could generate an in-game credits screen from the licences we already vendor. |
| [KayKit City Builder Bits](https://github.com/KayKit-Game-Assets) | CC0 | Adopted in the fourth pass (above). |
| [Simplified Flight Simulation](https://github.com/fbcosentino/godot-simplified-flightsim) | MIT | We fly JSBSim. |

## The fourth pass: physics, textures, weather, fire, water, inventory (September 2026)

The gaps asked about, checked one by one on GitHub (the only reachable source):

| Want | Looked at | Verdict |
|---|---|---|
| Fire, smoke, explosions | [GDQuest godot-visual-effects](https://github.com/GDQuest/godot-visual-effects), [Kenney Particle Pack](https://github.com/shorepine/kenney) | GDQuest's shaders are MIT, but its art is **CC-BY-NC-SA** (non-commercial), so none of it was copied. The effects are ours: Kenney's CC0 sprites on `CPUParticles3D`, which draws the same on every renderer, the compatibility one included. |
| Water | [godot4-oceanfft](https://github.com/tessarakkt/godot4-oceanfft), [GodotOceanWaves](https://github.com/2Retr0/GodotOceanWaves), [Waterways](https://github.com/Arnklit/WaterGenGodot) | FFT oceans need compute shaders (Forward+ only), and Waterways is for Godot 3 rivers. Our ocean shader gained rain rings instead (below), plus splashes. |
| Rain and weather | [Sky3D](https://github.com/TokisanGames/Sky3D) (MIT, all renderers) | It would replace a sky we already have (sun, moon phases, clouds, a storm deck, lightning). What was missing was the world *getting wet*: a `rain_wet` shader global now darkens the ground and facades, puts a sheen on the roads, and rings the sea. It soaks through in about 2.5 minutes of storm and dries over about 15. |
| Fog | Godot's `FogVolume` (Forward+ only), Sky3D's fog | Storm fog already closes in. Sea fog is now weather in its own right (DESIGN §20). It's opt-in and has its own random stream, so the parity replays are untouched, and it's drawn as the environment's exponential fog, which works on every renderer. |
| Physics | Jolt (built into Godot since 4.4), [godot-jolt](https://github.com/godot-jolt/godot-jolt) (now archived upstream) | Switched to the built-in Jolt. Blasts now throw debris that tumbles and settles on the ground (capped, and it clears itself). Bales stay simulation-driven, because the airdrop's outcome is the simulation's. |
| Textures | [Kenney Prototype Textures](https://github.com/shorepine/kenney); Poly Haven and ambientCG are unreachable (not on GitHub) | The terrain, city and water are procedural (`texgen.gd`, splat shaders) at any resolution. Photo textures would clash with the low-poly look, so nothing was taken. |
| Inventory | [GLoot](https://github.com/peter-kish/gloot) (MIT, 4.4+), [Expresso Inventory System](https://github.com/expressobits/inventory-system) (MIT, C++), [Inventory Manager](https://github.com/Rubonnek/inventory-manager) | GLoot is the best of them, but its `Inventory` is a scene-tree Node, and ours has to live in the host-authoritative simulation and replicate. An on-foot pack of six kinds of thing is about 100 lines of `FootCombat`: it has a weight limit, slows you when heavy, keeps the other gun when you switch, takes and returns to the armoury, and holds medkits. Arrested, it becomes the task force's evidence. GLoot is the pick if inventory grows into containers, trading or grids. |
| Street props | [KayKit City Builder Bits](https://github.com/KayKit-Game-Assets/KayKit-City-Builder-Bits-1.0) | Adopted (above). |
| Read aloud | GATO TTS | Adopted as Godot's own TTS (above). |

## Looked at, not a fit

| Library | Why not |
|---|---|
| [godot4-oceanfft](https://github.com/tessarakkt/godot4-oceanfft) (FFT ocean, buoyancy) | Compute shaders: Forward+ only. It could be an optional "ultra" water later; boats in the sim are kinematic anyway. |
| [Gerstner waves and buoyancy](https://github.com/stvgale/Gerstner-Waves-Buoyancy-Effects-Godot-4), [Godot-Ocean-Shader](https://github.com/immaculate-lift-studio/Godot-Ocean-Shader) | Our ocean shader already does Gerstner-style waves; nothing to gain. |
| [Terrain3D](https://github.com/TokisanGames/Terrain3D) | The terrain is generated natively and read by the sim (radar line-of-sight, landings), so it can't be swapped for an editor terrain. |
| [GodotJSBSim](https://github.com/lewhfree/GodotJSBSim), [jsbgodot](https://github.com/chunky/jsbgodot) | We already bind JSBSim ourselves, with the exact API the sim needs. |
| [GUT](https://github.com/bitwes/Gut) | We have our own headless test runner (`tools/test.sh`, 320+ tests); moving buys nothing. |

Sources: [awesome-godot](https://github.com/godotengine/awesome-godot) (the curated list), and each project's repository above.

## Godot 4.7

The project moved from 4.4.1 to **4.7.2** (the latest stable). The worries that had held it back didn't come true:
- **JSBSim.** GDExtensions are forward-compatible: `native/`, built against the 4.4.1 `godot-cpp` (`compatibility_minimum = "4.4"`), loads in 4.7 unchanged, and the flight model still matches the Python build bit for bit (`test_fdm_native` and every parity fixture pass). godot-cpp now has its own versions (10.0.0); a rebuild against it can wait until an API we need is missing.
- **Vendored addons.** Dialogue Manager v3.10.5, Input Helper, the CRT and colour-blindness shaders and the Kenney and KayKit kits all work: all 459 tests pass on 4.7.2, the same as on 4.4.1.
- **One break.** 4.7 enforces an overridden virtual's return type: the screenshot tools' `_process` (a `MainLoop` override, which returns a bool that quits when true) now declares `-> bool` and returns false.
- **Rendering.** The same frames render identically under the compatibility renderer (llvmpipe).
- **The shader baker** (since 4.5) is switched on in the export presets, so a release build compiles its shaders ahead of time instead of stuttering on first sight. First-sight frame times still want measuring on real hardware (F6).
