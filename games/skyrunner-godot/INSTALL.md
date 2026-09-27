# Installing Skyrunner

A step-by-step guide to getting the game running. There are two ways in:

| Way | For | Time |
|---|---|---|
| **A. Download a build** | playing and testing | about 5 minutes |
| **B. Run from source in Godot** | modding, the newest code, Linux ARM or anything without a build | about 10 minutes |

Nothing needs compiling either way: the game is pure Godot (GDScript), with no plug-ins or native
libraries.

## What you need

- **Windows 10 or 11, Linux or macOS 11+**, 64-bit.
- **A graphics card with Vulkan** (Windows and Linux) or **Metal** (macOS). Most cards from 2014 on
  qualify. Older or missing GPUs can use the OpenGL fallback (see [Troubleshooting](#troubleshooting)).
- **About 250 MB** of disk space, plus a few MB for saves.
- A keyboard. A joystick, yoke, throttle quadrant, rudder pedals or gamepad are optional; all can be
  bound in game with F8.
- For way A: a **GitHub account** with access to this repository. GitHub only lets signed-in users
  download CI builds.

---

## A. Download a build

### 1. Get the zip

1. Open the repository on GitHub and click **Actions** (top bar).
2. On the left, choose the workflow **Skyrunner beta builds**.
3. Click the newest run with a **green tick** ✓. Runs on the `claude/cargo-flight-game-2g413p`
   branch hold the beta.
4. Scroll to **Artifacts** at the bottom of the run's page and download the one for your system:

   | Artifact | System | Size |
   |---|---|---|
   | `skyrunner-windows` | Windows 10/11, x86_64 | ~41 MB |
   | `skyrunner-linux` | Linux, x86_64 | ~32 MB |
   | `skyrunner-macos` | macOS 11+, Intel and Apple Silicon | ~63 MB |

Artifacts are kept for 90 days. If the list is empty, a newer run will have them.

### 2. Install and start it

#### Windows

1. Right-click `skyrunner-windows.zip` → **Extract All…**, and pick a folder you own
   (for example `Documents\Skyrunner`, not `Program Files`).
2. Open the folder. Keep **`Skyrunner.exe` and `Skyrunner.pck` together**: the `.pck` is the game's
   data.
3. Double-click **`Skyrunner.exe`**.
4. Windows SmartScreen may say *"Windows protected your PC"*, because the beta isn't signed. Click
   **More info → Run anyway**. This is needed only the first time.
5. Optional: right-click `Skyrunner.exe` → **Send to → Desktop (create shortcut)**.

#### Linux

```bash
mkdir -p ~/Games/Skyrunner && cd ~/Games/Skyrunner
unzip ~/Downloads/skyrunner-linux.zip
chmod +x Skyrunner.x86_64      # GitHub's zip drops the executable bit
./Skyrunner.x86_64
```

- Keep `Skyrunner.pck` next to the binary.
- On a minimal install you may need the Vulkan loader and your GPU's driver, e.g.
  `sudo apt install libvulkan1 mesa-vulkan-drivers` on Debian/Ubuntu.
- Optional desktop entry (`~/.local/share/applications/skyrunner.desktop`):

  ```ini
  [Desktop Entry]
  Type=Application
  Name=Skyrunner
  Exec=/home/YOU/Games/Skyrunner/Skyrunner.x86_64
  Path=/home/YOU/Games/Skyrunner
  Terminal=false
  Categories=Game;
  ```

#### macOS

1. Double-click `skyrunner-macos.zip`. It unpacks to a folder containing **`Skyrunner.zip`**;
   double-click that too, to get **`Skyrunner.app`**.
2. Drag `Skyrunner.app` into **Applications** (or anywhere you like).
3. The beta isn't notarized by Apple, so the first launch is blocked. Either:
   - **right-click** (or Control-click) `Skyrunner.app` → **Open** → **Open**, or
   - on macOS 15+, try to open it once, then go to **System Settings → Privacy & Security** and
     click **Open Anyway**, or
   - in Terminal:

     ```bash
     xattr -dr com.apple.quarantine /Applications/Skyrunner.app
     ```
4. After that it opens normally. The app runs natively on both Intel and Apple Silicon Macs.

---

## B. Run from source in Godot

1. **Install Godot 4.7** (the standard build, *not* the .NET one) from
   <https://godotengine.org/download>. The game is tested on **4.7.2**; older versions are listed
   in the download archive. On Linux, `./tools/get_godot.sh` fetches the exact version into `.tools/`
   and prints its path.
2. **Get the code**:

   ```bash
   git clone <this repository's URL>
   cd AutoGPT
   git checkout claude/cargo-flight-game-2g413p
   ```
   Or GitHub → **Code → Download ZIP** on that branch.
3. **Open the project**: start Godot, click **Import**, choose
   `games/skyrunner-godot/project.godot`, then **Import & Edit**. The first import takes a minute.
4. **Play**: press **F5**, or the ▶ button top right.

From a terminal, without the editor:

```bash
cd games/skyrunner-godot
godot --path .                          # the lobby
godot --path . -- --unlocks open        # straight into open mode
./tools/test.sh                         # the test suite (headless, ~7 minutes)
```

To make your own builds: **Project → Export…** in the editor (the Linux, Windows and macOS presets
are already set up; Godot offers to download the export templates), or
`godot --headless --export-release Linux export/linux/Skyrunner.x86_64`.

---

## First launch

1. The **lobby** opens. For a first game:
   - leave **Unlocks** on *Story* (the 1979–1989 campaign; *Open* has everything from the start);
   - tick **Tutorial** for lessons as you play;
   - click **FLY**.
2. **Loading takes a few seconds** on a black screen while the map is built.
3. You're in a Cessna 172 on the ramp at San Telmo. Press **F1** for every key, and **J** for the job
   board. The basics:

   | Keys | Does |
   |---|---|
   | W / S or Up / Down | pitch |
   | A / D or Left / Right | roll |
   | Q / E | rudder and nosewheel |
   | R / F, or PgUp / PgDn | throttle (Z full, X cut) |
   | G / T | flaps down / up |
   | B or Space | brakes |
   | C | camera (chase, cockpit, tower) |
   | L | load planner and fuel |
   | F8 | controls: rebind keys, bind a joystick, yoke or pedals |
   | F12 | save a feedback bundle for a bug report |
   | Esc | close a menu, or quit |

   F1 in game is the full, current list.
4. **Graphics**: the lobby's *Graphics* setting, or start with `--graphics low|medium|high`.

---

## Where your files are

| | Windows | Linux | macOS |
|---|---|---|---|
| Saves and settings | `%APPDATA%\Godot\app_userdata\Skyrunner\` | `~/.local/share/godot/app_userdata/Skyrunner/` | `~/Library/Application Support/Godot/app_userdata/Skyrunner/` |

In that folder:
- `story.json`, `save.json` and `campaign.json` are the saves;
- `controls.cfg` and `settings.cfg` are your bindings and options;
- `feedback/` holds the F12 bundles;
- `terrain/` is the cache for generated islands;
- `logs/godot.log` is the log.

To start completely fresh, delete that folder.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| **Black window, crash at start, or "Vulkan" errors** | Your GPU or driver lacks Vulkan. Start with the OpenGL renderer: `Skyrunner.exe --rendering-driver opengl3` (make a shortcut with that in *Target*), or `./Skyrunner.x86_64 --rendering-driver opengl3`. Update your graphics driver too. |
| **Very low frame rate** | Start with `-- --graphics low`, close other 3D apps, and on laptops make sure the game runs on the dedicated GPU. F6 shows the frame times. |
| **"Couldn't load project data" / the game quits at once** | `Skyrunner.pck` isn't next to the executable, or the zip wasn't fully extracted. Extract the whole zip again. |
| **Linux: "Permission denied"** | `chmod +x Skyrunner.x86_64` |
| **macOS: "is damaged and can't be opened"** | That's the quarantine flag, not damage: run the `xattr` command above. |
| **Windows: the exe vanishes after download** | Some antivirus tools quarantine unsigned games. Restore it, or add an exception for the folder. |
| **No sound on Linux** | The game uses PulseAudio or PipeWire via ALSA. Check that `pavucontrol` shows it and that it isn't muted. |
| **Joystick not detected** | Plug it in before starting the game, then press F8 → the axis rows → *Capture* and move the control. |
| **Text-to-speech does nothing** | It needs the system voice: Windows and macOS have it built in; on Linux install `speech-dispatcher`. |
| **Multiplayer: friends can't connect** | The host needs TCP port **47800** open (or `--port N`) in its firewall and router. Friends join with `--connect HOST_IP:47800`, or through the lobby. |

Still stuck? Press **F12** in game (or send `logs/godot.log` from the folder above) and include it
in your report. See [BETA.md](BETA.md) for what to test and how to report.

## Uninstalling

Delete the game folder (or `Skyrunner.app`), then the saves folder from the table above if you
want those gone too. Nothing else is installed: no registry entries, services or drivers.
