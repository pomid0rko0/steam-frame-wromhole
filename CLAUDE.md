# Notes for agents working on this repo

Read README.md first (Russian): what the project is, where it comes from (optozorax's video
and his `portal` project), the geometry, the method, the stereo convention, the Steam Frame,
the branches and the wishlist.

## Who and how

- **The owner** (GitHub `pomid0rko0`) speaks Russian; answer in Russian.
- **Their setup:** a Valve Steam Frame (standalone VR headset, SteamOS), a Windows 11 PC and an Android phone, all on one Wi-Fi (often the phone's hotspot). SSH into the Frame is enabled with a password.
- **How builds reach the headset:** the owner installs them with `tools/deploy_frame.bat` (their user and address are filled in locally, not in the repo), runs them and tells you what they see.
- **The owner can't judge test images or numbers.** Verifying is your job. Anything they must check in the headset has to be a simple yes/no they can see, like the one-eye check in the README.
- **You have no headset and no GPU:** a cloud Linux container with software Vulkan (lavapipe) and xvfb. Monado gives a simulated OpenXR runtime. `godot/tests/fake_hmd.gd` is a scripted headset through Godot's real multiview path.
- **One wish per chat,** starting from the branch listed below for it.
- **Versions are git tags,** set on a commit once the owner has checked it in the headset. Don't put versions or a history of builds into docs or comments; git keeps them.
- **Deliver a build** as `wormhole_vr_<label>_steam_frame.zip` holding one `.arm64`, and actually attach it to the chat.

## Branches

Each wish has its own branch from `main`, so each can be checked in the headset alone. Only
`grab` holds more: `walking` and `physics` merged (grabbing works on `physics` balls, and the
stick takes you to them). `main` has been checked in the headset (rendering and stereo, with the
one-eye check; its tag marks the commit), the others have not; each README describes its code.

- `main` — the wormhole, static objects, walking in the room, the stereo check scene (off), the
  frame rate panel: it follows the head, measures the rate and missed frames, and its buttons
  (point a controller, pull the trigger) set the refresh rate and the render scale.
- `walking` — the left stick walks (left trigger runs), the right stick snap-turns 30°, A goes
  back to the start (`tests/walking_test.gd`).
- `throat` — throat knobs: the right stick up/down changes the throat length, with the right
  grip held the fillet; A resets (`tests/throat_test.gd`).
- `physics` — balls with physics in the curved space (`ball_world.gd`, `tests/physics_test.gd`).
- `grab` (`walking` + `physics`) — grip grabs and throws balls, B makes a new one, hands and
  the avatar as balls (`tests/grab_test.gd`).
- `foveation` — foveated rendering on, as it was when space "breathed" in the headset; the
  cause is not found.
- `fast-rays` — cheaper rays: the curved-region integral without loops (product integration on
  4 nodes, README «Почему это real time»), one shading per pixel after the trace, the ray's
  direction interpolated from the screen's corners, and the movable balls' code in a separate
  shader (`wormhole_balls.gdshader`, chosen by `main.set_balls`). Checked in the headset with
  5 nodes and the direction per pixel: the one-eye check passes; at the shell's edge a frame
  costs about 5 ms (16.6 on `main`), 108 Hz holds at 100%, 120 Hz at 90% (README «Что видно в
  шлеме»).
- `controls` — the old sketch that `walking`, `throat` and `grab` were split from (on
  `physics` on `refresh-rate`); don't start from it.

Where the README wishes start (wishes without a branch start from `main`):
- stick locomotion on the floor → `walking` (smooth stick walking and snap turn are there);
- free flight in 3D with gravity on/off → `walking` (the gravity field is in `physics`);
- pick up and throw, pulling objects like in Half-Life: Alyx → `grab` (grip grab and throw
  are there);
- cubes next to balls → `physics`;
- throat shape, VR-friendly knobs, test scenes → `throat` (throat length and fillet on the right
  stick);
- refresh rate and render scale → `main` (the panel is there); cheaper rays near the wormhole →
  `fast-rays` (`wh_curved` in `wormhole_core`, measured in the headset by the panel's `refresh:` lines;
  without a headset `tools/adreno_stats.sh`);
- foveated rendering → `foveation`;
- placing wormholes by hand, several wormholes, flat portals, two-handed shooting, gun models,
  other shapes (torus, arbitrary SDF) → `main`; several wormholes, portals and other shapes are
  renderer work (`wormhole_core` and a reference in `ref/` first);
- the avatar: its head ball around the eyes makes every ray inside the throat sample it finely
  and the frame drops; it is off by default in `grab`.

When branches are put together, these overlap:
- the left trigger: on `main` a trigger presses the panel's button its controller points at,
  `walking` runs with the left one. Together: no running while the left ray is on the panel
  (`perf.on_plate[0]`).
- the right stick: x turns in `walking`, y changes the throat in `throat`; that fits.
- A resets in `walking`, `throat` and `grab`: one reset does all of it.
- a throat change with balls (`throat` + `physics`): balls must keep their distance to the
  edge of the curved shell, as the feet do in `set_geometry`.
- `fast-rays` with `physics` or `grab`: they set `wh_ball` / `wh_nBall` on the material; with
  `fast-rays` that goes through `main.set_balls`, which also switches to the shader with balls
  (the one without them has no ball code at all and ignores them).

## Hard rule: stereo before headset

Broken stereo physically hurts in a headset. Before handing over any headset build, run
`tools/test_stereo.sh` on exactly that source; it must pass (exit 0). If you add things Godot
draws next to ray-traced ones, check they line up the same way.

## Running things

- **Fresh machine:** `tools/setup.sh` downloads Godot 4.7.2 into `tools/.bin` (and links it as `godot` in `/usr/local/bin`), the export templates and the pip packages, and installs xvfb, lavapipe and EGL with apt if they are missing.
- **Fresh clone:** run `godot --headless --path godot --import` once before running test scripts with `-s`, or `class_name` types such as WormholeSpace are unknown. `test_stereo.sh` does it itself.
- **Stereo:** `tools/test_stereo.sh` (~15 min).
- **Tracer accuracy:** `python3 ref/test_gpu.py` (~4 min; needs EGL: `libegl1 libegl-mesa0`, which `setup.sh` installs), `ref/test_fast.py`, `ref/test_eye.py`. It prints errors, no verdict: compare them with the same run on the code before a change (`WH_BALLS=0` too: it compiles the shader without balls). `ref/wh.py` `fast` mirrors the shader's curved-region method in float64; keep the two in step.
- **What the headset's compiler makes of the shader:** `tools/adreno_stats.sh [scene]` (3 s): Godot on Mesa's Turnip (Adreno 750) over the noop drm-shim, which `setup.sh` builds into `tools/.bin/mesa-fd`; it prints instructions, nops, registers and waves of the ray tracer (Godot compiles it twice: a generic ubershader, then the specialised one). The numbers that matter on the Frame: registers per pixel set the waves at once (48 → 4, 24 → 8, 16 → 12, 13 → 14; at 12 or fewer the compiler runs waves of 128), and the instructions a ray runs. No timings: there is no GPU.
- **Tests:** on `main`, `--xr-mode off -s res://tests/refresh_rate_test.gd` (the rate meter, the verdict, the GPU clock) and `tools/test_openxr.sh` (the panel and its buttons); each branch's own, `--fixed-fps 60 -s res://tests/<name>_test.gd` (`walking`, `throat`, `physics`, `grab`).
- **Export:** from `godot/`: `--export-release "Steam Frame (Linux arm64)" build/wormhole_vr.arm64`.
- **OpenXR without a headset:** `tools/test_openxr.sh`: `monado-service` with `XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1`, whose stdin must be a pipe or FIFO (it epolls stdin and quits at once on `/dev/null`). Its null compositor offers one rate, 20 Hz, 128×128 per eye, and paces a slow app at every 2nd refresh with a doubled `predictedDisplayPeriod`. Reading eye images back fails there; for images use `fake_hmd.gd` or Godot's "Native mobile" interface. While `monado-service` runs, any Godot started here connects to it as a headset: don't run `test_stereo.sh` at the same time (its desktop check then sees Monado's head pose and fails).
- **GitHub from this environment:** branch pushes work through the session's git proxy, tag pushes are refused (403). The owner creates tags on GitHub.

## Things learned the hard way

- **Godot multiview.** `INV_VIEW_MATRIX` is a shared camera between the eyes; each eye's offset and rotation live in its `PROJECTION_MATRIX`; `EYE_OFFSET` is the eye in that view space. Rays must start at the eye (README, «Стерео»). Starting them at the head centre made the eyes look in different directions.
- **The overlay's chart → play map** is computed at placement and recentre (and in `walking` after stick moves and turns), never every frame from the feet. Then it is fixed to the room, and world drift shows as green parting from white.
- **Foveated rendering** (VRS, `xr/openxr/foveation_*`) made space "breathe" around the head and caused nausea on the Frame. It is off; don't turn it on without a headset check.
- **SteamVR on the Frame** shows a non-Steam app's desktop window on a virtual screen inside the headset. So XR renders into a SubViewport and the window only shows a notice.
- **Refresh rate.** The Frame starts this app at 72 Hz; its display does 72/80/90/96/108/120/144. Other developers report that SteamVR there answers `XR_FB_display_refresh_rate` requests with success and ignores them. It follows the app's own setting `steam.app.<SteamAppId>.preferredRefreshRate`, set with `/opt/steamvr/bin/linuxarm64/vrcmd`; on our Frame (SteamVR 2.18.2) the running app switches within a second, and `xrGetDisplayRefreshRateFB` then reports the true rate. `refresh-rate`'s panel does that from its rate buttons and measures the rate and missed frames from xrWaitFrame's timing (`rate_meter.gd`); its `refresh:` log lines are the data. Measured at 1728×1728 per eye (README, «Что видно в шлеме»): 72 and 80 Hz keep up, 90 Hz falls to every 2nd refresh at times, 96–120 Hz mostly at every 2nd; the GPU stays at its top clock (903 MHz), and a frame costs 6.5–7.7 ms with the wormhole small in view, 11–12 ms with it large: the rays through the curved region are the cost. SteamVR there does not offer `XR_EXT_performance_settings`.
- **Kernel files.** A sysfs file reports a size of 4096 bytes whatever it holds, and `FileAccess.get_file_as_string` reads that many: garbage after the value, and on the Frame a log full of Unicode errors. Read them with `get_line()` (`perf_panel.gd`, `read_line`).
- **Logs on the Frame:** `~/.local/share/godot/app_userdata/Wormhole VR/logs/`; `tools/frame_logs.bat` fetches them. `application/run/flush_stdout_on_print` is on, or the running app's log lost its last lines. The desktop window's V-Sync mode Disabled is not available there (Godot falls back to Enabled), and the app still reached 144 Hz.
- **Signals of the OpenXR interface.** A GDScript lambda connected to an `OpenXRInterface` signal by the panel corrupted the heap at exit (under Monado); a method callable did not. `tools/test_openxr.sh` fails on a crash at exit.
- **SceneTree test scripts.** In them `main._ready` has not run during `_initialize`; touch main's nodes from `_process` (frame 2 or later). Settings applied too early silently do nothing.
- **Software-Vulkan timings** are only good for ratios, and not for the shader's inner costs: halving the curved-region Simpson steps changed lavapipe's frame by 1%, while on the Frame the curved-region rays double the frame. `tests/perf.gd` `near` / `away` (6.5 m from the centre, facing it / away) separate them. For the Frame's own compiler use `tools/adreno_stats.sh`.
- **Registers are taken by code no pixel runs.** The GPU reserves a shader's registers for its heaviest point, so the movable balls' code (12 unrolled candidate loops with bisections) held the plain scene at 48 registers and 4 waves with no balls in it. Loops over balls run to `wh_nBall` (a constant bound with `break` is unrolled 12 times), candidates are bit masks, not arrays, and the scene without balls uses the shader built with `WH_NO_BALLS`. On Turnip a 4-wave shader is a slow one, whatever it computes.
- **Derivatives in the shader** (`fwidth` for the grid lines) are only defined in uniform control flow: `wh_render` computes the lines' coordinates for every pixel and their `fwidth` once, after the trace.
- **Godot shading language** reserves `E`, `PI`, `TAU` as built-in constants: a local variable `E` is a compile error in Godot that GLSL (`ref/`) accepts. `tools/test_stereo.sh` and `adreno_stats.sh` fail on shader errors.
- **Render scale and the stereo test.** At a 3D render scale below 1 the bilinear upscale blends the balls' edges with the background, and the one-colour red threshold of `tools/compare` then shifts the shaded ray-traced ball by 0.2–0.4 px against Godot's flat red one. With `SCALING_3D_MODE_NEAREST` the whole suite passes at 80% within 0.02 px: the geometry is exact, test a scale that way.
- **Balls in the shader.** A ball far from the throat must not be a candidate in the curved-region integrator (`wormhole_core`), or every ray through the throat samples it finely. A ball around the eye (the avatar's head) still does that inside the throat.
- **The one-eye check in the headset** is what catches problems only the real device has. Run it after any change to rendering.
