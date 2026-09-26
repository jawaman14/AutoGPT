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
| [Kenney's 3D kits](https://github.com/shorepine/kenney) | CC0 | The people, cars, guns, boats and palms (`assets/models/kenney/`, see the README). |
| [JSBSim](https://github.com/JSBSim-Team/jsbsim) | LGPL-2.1 | The flight model, through our own GDExtension (already in use). |

## Worth adopting next

| Library | Licence | Where it would go | Cost / risk |
|---|---|---|---|
| [Dialogue Manager](https://github.com/nathanhoad/godot_dialogue_manager) | MIT | Scripted conversations for the Family's offers, the General's aide, the Company's contact and a defector's plea, in place of one-line messages. Branches could carry the "read" (what you notice) as choices. | Medium: a new UI layer. The sim stays as it is; the dialogue only calls `family_accept` and the like. |
| [Phantom Camera](https://github.com/ramokz/phantom-camera) | MIT | The demo tours and cinematic shots (follow, framing, tweened cuts) instead of hand-lerped cameras in `tools/*_tour.gd`. | Low: tools only. |
| [netfox](https://github.com/foxssake/netfox) | MIT | Lag compensation and client prediction for the remote pilot seat, or for on-foot combat between human players. | High: our protocol v3 is authoritative and snapshot-based, so this would be a partial adoption at most. |
| [LimboAI](https://github.com/limbonaut/limboai) or [Beehave](https://github.com/bitbrain/beehave) | MIT | Behaviour trees for new AI that isn't in the parity replays (the Family's and the island's actors, squad tactics). | Medium: the current utility and state code is tested and deterministic; a behaviour tree must keep its own RNG streams. |

## Looked at, not a fit

| Library | Why not |
|---|---|
| [godot4-oceanfft](https://github.com/tessarakkt/godot4-oceanfft) (FFT ocean, buoyancy) | Compute shaders: Forward+ only. It could be an optional "ultra" water later; boats in the sim are kinematic anyway. |
| [Gerstner waves and buoyancy](https://github.com/stvgale/Gerstner-Waves-Buoyancy-Effects-Godot-4), [Godot-Ocean-Shader](https://github.com/immaculate-lift-studio/Godot-Ocean-Shader) | Our ocean shader already does Gerstner-style waves; nothing to gain. |
| [Terrain3D](https://github.com/TokisanGames/Terrain3D) | The terrain is generated natively and read by the sim (radar line-of-sight, landings), so it can't be swapped for an editor terrain. |
| [GodotJSBSim](https://github.com/lewhfree/GodotJSBSim), [jsbgodot](https://github.com/chunky/jsbgodot) | We already bind JSBSim ourselves, with the exact API the sim needs. |
| [GUT](https://github.com/bitwes/Gut) | We have our own headless test runner (`tools/test.sh`, 320+ tests); moving buys nothing. |

Sources: [awesome-godot](https://github.com/godotengine/awesome-godot) (the curated list), and each project's repository above.
