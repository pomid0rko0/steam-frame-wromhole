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
- **Name the branch yourself.** The session hands you a `claude/<random-name>` branch: don't use it. Name the wish's branch with a short English word (`throat`, `grab`), start it from the branch listed below for the wish, and push there. The owner allows this; it is their standing permission to push to a branch other than the one the session gives you.
- **Versions are git tags,** set on a commit once the owner has checked it in the headset. Don't put versions or a history of builds into docs or comments; git keeps them.
- **Deliver a build** as `wormhole_vr_<label>_steam_frame.zip` holding one `.arm64`, and actually attach it to the chat.

## Branches

Each wish has its own branch from `main`, so each can be checked in the headset alone. Only
`grab` holds more: `walking` and `physics` merged (grabbing works on `physics` balls, and the
stick takes you to them). `main` has been checked in the headset (rendering and stereo, with the
one-eye check; its tag marks the commit), the others have not; each README describes its code.

- `main` — the wormhole, static objects, walking in the room, the stereo check scene (off), the
  frame rate panel: it follows the head, measures the rate and missed frames, and its buttons
  (point a controller, pull the trigger) set the refresh rate and the render scale. Stick
  locomotion (from `walking`): the left stick walks (left trigger runs, not while the left ray is
  on the panel), the right stick turns smoothly or in 30° snaps (a right stick click switches), A
  goes back to the start (`tests/walking_test.gd`, `tests/walking_xr_test.gd`). Checked in the
  headset: all of it works, a little nausea, bearable; crossing the shell's outer edge by stick is
  clean (before `fast-rays` the picture glitched there: frames dropped at 16.6 ms). The cheaper
  edge frames of `edge-120hz` (merged, below) and the cost model are in it too. Foveated
  rendering (from `foveation`, merged, below) is on by default: our narrow map, the width first.
- `walking` — merged into `main`; stick locomotion wishes start from `main` now.
- `throat` — throat knobs: the right stick up/down changes the throat length, with the right
  grip held the fillet; A resets (`tests/throat_test.gd`).
- `physics` — balls with physics in the curved space (`ball_world.gd`, `tests/physics_test.gd`).
- `grab` (`walking` + `physics`) — grip grabs and throws balls, B makes a new one, hands and
  the avatar as balls (`tests/grab_test.gd`).
- `foveation` — merged into `main`: foveated rendering from the panel: SteamVR's density map
  low/high (`XR_FB_foveation`) or our own softer ones, wide/narrow (`main.OWN_MAPS`,
  `VRS_TEXTURE`; each ring halves the rays, the width or the height first, `main.set_own_order`),
  all moved to where the eyes look (`XR_META_foveation_eye_tracked` → QCOM offsets)
  (`main.set_foveation`); the 3D scene in a render pass of its own so that Turnip renders it in
  tiles (`split_pass.gd`; without tiles the map does nothing); a gaze dot (`main.gaze_dot`,
  `XR_EXT_eye_gaze_interaction`); the speed check timing this build six ways; `tools/fdm_check.sh`.
  Checked in the headset: the maps follow the gaze; GPU per frame against before -41% / -50%
  (SteamVR low / high), -9% / -38% (own wide / narrow); 120 Hz tours clean; our narrow map with
  the width first at 144 Hz, 100%: "all super", no border to see, no frame missed in play (only in
  the second of a switch). The height first shows in the periphery (the floor seen at a grazing
  angle has more detail up and down). Default: narrow, the width first (`perf_panel.DEFAULT_*`).
- `fast-rays` — cheaper rays: the curved-region integral without loops (product integration on
  4 nodes, README «Почему это real time»), the ray's direction interpolated from the screen's
  corners, one shading per pixel after the trace, the movable balls' code in a separate shader
  (`wormhole_balls.gdshader`, chosen by `main.set_balls`), and the speed check (`bench.gd`,
  `tools/ab_shaders.sh`). Measured in the headset by the speed check: 4.7-5 ms at the shell's
  edge (16.6 before), 120 Hz held on its whole tour; frames drop at the edge when SteamVR shows
  the cameras (README «Что видно в шлеме»). Next: cheaper shading, a table for the curved region
  (README wish «Дешевле лучи у червоточины»).
- `edge-120hz` — merged into `main`: cheaper frames at the shell's edge, for 120 Hz while SteamVR
  shows the cameras (~3.5 ms needed): per-eye values once per eye, the curved-region floor test
  without `atan` for rays that miss the floor, the fillet coefficients from a table by impact
  parameter (`WormholeSpace.fillet_table`, plain shader only), 4 screen derivatives instead of 6,
  one sky for both worlds, own `atan`/`asin`, the fog's path length estimated (12 registers),
  world B's boxes skipped by rays going up above them, fewer roots. Same picture (within 1/255),
  accuracy and stereo; one-eye check passed. Measured by the speed check: the edge 4.73 → 3.6 ms,
  -23% over world A's poses, 120 Hz tour 0 missed of 20630. Not solved: 144 Hz in world B at
  5.5-6 m facing the throat (4.8 ms, frames up to 6; README «Мир B у внешнего края дороже всего»).
- `gravity` — gravity through the wormhole from Laplace's equation, as in optozorax's video about
  gravity and portals (README «Гравитация через червоточину»): the math from `physics` (e493a20:
  `ref/gravity.py`, `ref/test_gravity.py`, `WormholeSpace.gravity_f`, `potential`, `potential_grad`,
  `floor_gravity`, all in doubles) and a view of it on `main`'s fast core: the floor coloured by its
  strength, arrows of the field on the surface x = 0 through the wormhole (`wormhole_gravity.gdshader`,
  `wormhole_arrows.gdshader`, `main.set_gravity_view`; the panel's row, left Y, G;
  `tests/gravity_test.gd`, `ref/test_slice.py`). The plain shader compiles exactly as on `main`; the
  model: the floor view +5%, the arrows +28% (`tools/adreno_cost.sh --gravity 1|2`).
- `controls` — the old sketch that `walking`, `throat` and `grab` were split from (on
  `physics` on `refresh-rate`); don't start from it.

Where the README wishes start (wishes without a branch start from `main`):
- stick locomotion on the floor → `main` (smooth stick walking, smooth and snap turn are there);
- free flight in 3D with gravity on/off → `main` (the honest gravity field is in `gravity`:
  `WormholeSpace.potential_grad`; `physics` has it too, with balls on the old core);
- pick up and throw, pulling objects like in Half-Life: Alyx → `grab` (grip grab and throw
  are there);
- cubes next to balls → `physics`;
- throat shape, VR-friendly knobs, test scenes → `throat` (throat length and fillet on the right
  stick);
- refresh rate and render scale → `main` (the panel is there; the owner wants no automatic way
  out of SteamVR's half rate for now); cheaper rays near the wormhole → `main` (`wh_curved` in
  `wormhole_core`, measured in the headset by the speed check; without a headset
  `tools/adreno_cost.sh`, then `tools/adreno_stats.sh`); next there: world B's outer edge facing
  the throat, where the model misses ~1 ms;
- foveated rendering → `main` (merged from `foveation`; the sharp zone is whole tiles, the
  driver's limit);
- placing wormholes by hand, several wormholes, flat portals, two-handed shooting, gun models,
  other shapes (torus, arbitrary SDF) → `main`; several wormholes, portals and other shapes are
  renderer work (`wormhole_core` and a reference in `ref/` first);
- the avatar: its head ball around the eyes makes every ray inside the throat sample it finely
  and the frame drops; it is off by default in `grab`.

When branches are put together, these overlap:
- the left trigger, on `main`: a trigger presses the panel's button its controller points at, and
  the left one runs, but not while the left ray is on the panel (`perf.on_plate[0]`).
- the right stick: x turns on `main` (its click switches smooth/snap), y changes the throat in
  `throat`; that fits.
- the speed check (`bench.gd`) sets the viewer's pose itself: while it runs (`main.hold`) the
  sticks and A do nothing. `grab` and `throat` add their own buttons: keep them out of it too (`gravity`'s Y, G and panel
  row are).
- A resets on `main`, in `throat` and `grab`: one reset does all of it.
- left Y shows gravity in `gravity` and in `physics` (the same views; `physics` draws them on the
  old core): keep `gravity`'s. Its views are ray tracers without movable balls: with `physics` or
  `grab` the balls vanish while a view is on (a variant with both is new work).
- a throat change with balls (`throat` + `physics`): balls must keep their distance to the
  edge of the curved shell, as the feet do in `set_geometry`.
- a throat change (`throat`) with `main`'s fillet table: the table depends on the shape: after
  `space.set_profile`, `main._upload_fillet_table()` again (3 ms in GDScript on the desktop). The
  same for `gravity`: `set_profile` rebuilds the gravity table, `main._upload_gravity()` sends the
  shader its polynomials again.
- foveation (on `main`) and the render scale: the panel lets one of them be on (the eye-tracked
  map's offsets are in full-size pixels). Its rows sit under the scale's; its split pass is on the
  XR camera's compositor: an effect added there by another branch splits the pass as well. The
  action map has the eye gaze profile (`eye_gaze_pose` on `/user/eyes_ext`). Branches started
  before the merge start with foveation off; merged with `main`, they get it on by default.
- `fast-rays` with `physics` or `grab`: they set `wh_ball` / `wh_nBall` on the material; with
  `fast-rays` that goes through `main.set_balls`, which also switches to the shader with balls
  (the one without them has no ball code at all and ignores them).

## Hard rule: stereo before headset

Broken stereo physically hurts in a headset. Before handing over any headset build, run
`tools/test_stereo.sh` on exactly that source; it must pass (exit 0). If you add things Godot
draws next to ray-traced ones, check they line up the same way.

## Running things

- **Fresh machine:** `tools/setup.sh` downloads Godot 4.7.2 into `tools/.bin` (and links it as `godot` in `/usr/local/bin`), the export templates and the pip packages, and installs xvfb, lavapipe, EGL and Monado with apt if they are missing. A tool you had to install by hand goes into it too.
- **Fresh clone:** run `godot --headless --path godot --import` once before running test scripts with `-s`, or `class_name` types such as WormholeSpace are unknown. `test_stereo.sh` does it itself.
- **Stereo:** `tools/test_stereo.sh` (~5 min: the renders run in parallel, one Godot per core, each with its own display and shader cache; the check scene again with foveation on, and those pictures against the ones without).
- **Foveation in the Frame's driver:** `tools/fdm_check.sh` (~10 s): Godot on Turnip over the noop drm-shim, the XR view through `fake_hmd.gd` at 1728² per eye, and the driver's trace (`MESA_GPU_TRACES=print`, `TU_DEBUG=perf`) per render pass: in tiles or not, attachments, tiles. Off: no tiles; split: tiles; on: tiles and one attachment more (the density map).
- **A build for the one-eye check:** an empty file `godot/check` before the export turns the stereo check scene on (`main.CHECK_FLAG`, in the export's include filter, not in git); delete it afterwards.
- **Tracer accuracy:** `python3 ref/test_gpu.py` (~4 min; needs EGL: `libegl1 libegl-mesa0`, which `setup.sh` installs), `ref/test_fast.py`, `ref/test_eye.py`. It prints errors, no verdict: compare them with the same run on the code before a change (`WH_BALLS=0` too: it compiles the shader without balls). `ref/wh.py` `fast` mirrors the shader's curved-region method in float64; keep the two in step.
- **What the headset's compiler makes of the shader:** `tools/adreno_stats.sh [scene]` (3 s): Godot on Mesa's Turnip (Adreno 750) over the noop drm-shim, which `setup.sh` builds into `tools/.bin/mesa-fd`; it prints instructions, nops, registers and waves of the ray tracer (Godot compiles it twice: a generic ubershader, then the specialised one). The numbers that matter on the Frame: registers per pixel set the waves at once (48 → 4, 24 → 8, 16 → 12, 13 → 14; at 12 or fewer the compiler runs waves of 128), and the instructions a ray runs. No timings: there is no GPU.
- **Cost without a headset:** `tools/adreno_cost.sh [--check] [source]...` (sources as
  `ab_shaders.sh`, `this` = the tree; ~1 min each). Mesa's compiler for the Frame compiles the ray
  tracer, `tools/ir3_emu.py` runs the program it made (the specialised one) on waves at the speed
  check's poses (one eye, 1728², 104°) and counts issue cycles, divergent branches included
  (lowest PC first, as `ir3_reconvergence.c` describes). `--check` compares the emulated colours
  with Godot's lavapipe picture: run it after every change, it caught an emulator bug that had
  made a variant look 15% cheaper. Fitted on the headset's speed check (main and three variants
  of `edge-120hz`, nine poses of world A each): per 64 pixels, ms ≈ 0.8 + 1.61e-3 × ALU issue cycles +
  1.05e-3 × nop slots + 0.0258 × transcendentals (cat4) + 0.146 × texture-unit instructions
  (cat5: derivatives, samples); rms 0.19 ms, the variants' means within 5%. A transcendental
  costs ~16 ALU cycles, a screen derivative ~90. It does not know memory waits. Out of its fit it
  missed: 20% fewer transcendentals per pixel promised -7% and gave -0.7% in the headset, and in
  world B outside the edge (-5.7 m, 20° from the throat) it says 3.8 ms where the headset takes 4.8.
  `--profile` (adreno_cost.py) gives cycles per stretch of code.
  The flat inputs' packing (v_eye, v_l, v_n here) is found by matching the picture.
- **Measuring in the headset without the owner walking:** the panel's lowest button (or, in a
  build made with `tools/ab_shaders.sh --auto ...`, the start) runs `godot/bench.gd`. A frame's
  cost depends only on the pose (l, yaw from the throat, pitch, roll), so it goes through poses:
  (1) at 72 Hz, twelve fixed poses (three in world B), each timing every ray tracer in the build
  (`godot/shaders/ab/`, not in git: earlier commits, directories, or cost checks empty/flat/
  noshade/noderiv/nogrid/nosky made from the tree) in a palindrome order, `bench:` lines; (2) at 120 Hz, this build's
  ray tracer on a tour (view sweeps at ten l, walks through the throat, yaw/pitch/roll on the
  spot), a `tf` line per frame (time, pose, refreshes taken, GPU and CPU ms) and a `tour:` line
  per second. The panel ends with whether 120 Hz held and the comparison. Frame times from
  walking around do not compare between builds: where one looks changes them several times.
  The panel also logs a `refresh:` line every second (with where one looks) and one per late frame.
- **Pictures against another commit:** render both at many poses with `tests/emu_dump.gd`
  (`... -- out.json "l,yaw,pitch;..." fov plain|balls [shader]`) and diff the PNGs; `edge-120hz`
  matched the main before it within 1/255 at every pose.
- **Tests:** on `gravity`, `--rendering-method mobile --fixed-fps 60 -s res://tests/gravity_test.gd`
  under xvfb (the field against `ref/test_gravity.py`, Laplace, the shader's polynomials, the views'
  colours) and `python3 ref/test_slice.py` (the arrows' surface against RK4 rays, ~2 min); on `main`, `--xr-mode off -s res://tests/refresh_rate_test.gd` (the rate meter, the verdict, the GPU clock), `tools/test_openxr.sh` (the panel and its buttons) and `--fixed-fps 60 -s res://tests/walking_test.gd` / `walking_xr_test.gd` (the sticks, from keys and from controller trackers); each branch's own, `--fixed-fps 60 -s res://tests/<name>_test.gd` (`throat`, `physics`, `grab`).
- **Export:** from `godot/`: `--export-release "Steam Frame (Linux arm64)" build/wormhole_vr.arm64`.
- **OpenXR without a headset:** `tools/test_openxr.sh`: `monado-service` with `XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1`, whose stdin must be a pipe or FIFO (it epolls stdin and quits at once on `/dev/null`). Its null compositor offers one rate, 20 Hz, 128×128 per eye, and paces a slow app at every 2nd refresh with a doubled `predictedDisplayPeriod`. Reading eye images back fails there; for images use `fake_hmd.gd` or Godot's "Native mobile" interface. While `monado-service` runs, any Godot started here connects to it as a headset: don't run `test_stereo.sh` at the same time (its desktop check then sees Monado's head pose and fails). Monado's simulated controllers (`SIMULATED_LEFT=wmr`) bind to none of our profiles; for controller input use `XRControllerTracker`s with inputs set by hand (`tests/walking_xr_test.gd`).
- **GitHub from this environment:** branch pushes work through the session's git proxy, tag pushes are refused (403). The owner creates tags on GitHub.

## Things learned the hard way

- **Godot multiview.** `INV_VIEW_MATRIX` is a shared camera between the eyes; each eye's offset and rotation live in its `PROJECTION_MATRIX`; `EYE_OFFSET` is the eye in that view space. Rays must start at the eye (README, «Стерео»). Starting them at the head centre made the eyes look in different directions.
- **The overlay's chart → play map** is computed at placement and recentre (and after stick moves and turns), never every frame from the feet. Then it is fixed to the room, and world drift shows as green parting from white.
- **Foveated rendering on the Frame (Godot 4.7.2).** The Frame's SteamVR offers `XR_FB_foveation`
  (+ configuration, vulkan, swapchain update state), `XR_META_foveation_eye_tracked` and
  `XR_EXT_eye_gaze_interaction` (Valve's developer docs). Godot then attaches the runtime's density
  map (VK_EXT_fragment_density_map: on Qualcomm Godot prefers it to shading rate). Turnip applies
  a density map per tile, only when it renders in tiles (18 tiles of 288×576 per 1728² eye in
  Mesa 25.2), and it renders a render pass without tiles if any subpass dependency lacks
  `VK_DEPENDENCY_BY_REGION_BIT` ("Disabling gmem rendering due to invalid subpass dependency";
  25.2's trace then says "Can't fit attachments into gmem"). Godot 4.7.2's two-subpass pass (3D +
  tone map, used at render scale 100% without post effects) has such a dependency
  (godotengine/godot#124141, fixed by #124811 after 4.7.2): there the map did nothing. A
  CompositorEffect with a POST_TRANSPARENT callback (`split_pass.gd`, empty) makes Godot split the
  pass; FXAA, glow or a render scale below 1 do too. Also: subsampled images
  (`foveation_with_subsampled_images`, default on) SteamVR on the Frame can't read yet: off;
  Godot 4.7.2 asks for the eye-tracked offsets only with `xr/openxr/extensions/eye_gaze_interaction`
  on (#124787 drops that in 4.8), and in full-size pixels (wrong at a render scale below 1);
  `foveation_dynamic` reportedly does nothing on the Frame; the swapchain gets its density map only
  if `foveation_level` > 0 when it is created (so `project.godot` asks for 3 and "off" is
  `vrs_mode` = disabled). With `debug/settings/stdout/verbose_stdout` on (off now: hundreds of
  lines at each start) the headset's log lists the enabled OpenXR extensions and the driver's
  density map support. The headset's log: all those
  extensions, FDM offsets (granularity 8), no shading-rate VRS ("Variable Rate Shading not
  supported"): density only per tile, so the sharp zone is a rectangle of whole tiles. The offsets
  move whatever map is attached, so our own map (`VRS_TEXTURE`, a `Texture2DArray` set with
  `RenderingServer.viewport_set_vrs_texture`, since `Viewport.vrs_texture` takes a Texture2D only;
  `VRS_UPDATE_ALWAYS`, or a buffer rebuild leaves the driver's map empty) follows the eyes too.
  Godot maps a colour c to density 1 - c, Turnip a density d to 1/d floored to a power of two: 4x
  is byte 192 (191 gives 3.98, so 2).
- **The old "breathing".** With foveation first on (high, dynamic, subsampled), rays then from
  `SCREEN_UV`, the owner saw space around the head shrink and expand when turning, a little nausea,
  frames on time; the next build had it off (and the check grid fixed to the room, and the panel)
  and "all works". By the above the map did nothing at 100% then, so the cause is not proven: the
  foveated, subsampled swapchain in SteamVR's hands, or the lenses' distance (asked, never answered;
  eyes off the lens centres make the world warp as the head turns). The ray tracer now takes each
  pixel's ray from the corners' interpolation, never from its screen position, so a coarse pixel
  gets the ray through its centre: exact under any density map. With foveation working (eye
  tracked, our maps, 144 Hz) the owner saw no such thing.
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
- **Controllers.** Our action map has no profile of the Steam Frame's own (Godot 4.7.2 knows it, `/interaction_profiles/valve/frame_controller_valve`). On our Frame (SteamVR 2.18.2) the log's `interaction profile` lines show both controllers as `/interaction_profiles/khr/generic_controller`; its bindings (thumbstick, trigger, `primary/click` for A) are what the headset uses, and `walking_xr_test.gd` checks them. One path a runtime rejects drops that whole profile's bindings: Monado rejected `grip_surface/pose` (the palm pose) on Touch, and then no Touch input worked at all. The palm pose is unused here and out of the map.
- **Logs from a release build.** Without `application/run/flush_stdout_on_print` (on in `project.godot`) an export buffers `print()`, and an abort on quit loses every printed line from `godot.log`, the headset's too.
- **Tests with `fake_hmd.gd` abort at exit** (status 134) unless the interface and trackers are taken down first; `walking_xr_test.gd` does it, so its exit status means something.
- **Measure in the headset, not by counting instructions.** A rewrite of the flat trace (bounding balls, the hit's normal and colour picked at the end with dynamic indices) had fewer instructions for ir3 and was 7-15% slower on the Frame; 13 registers instead of 16 (14 waves instead of 12) made no difference. Compare variants with the speed check, at 72 Hz: at 120 Hz a variant that misses frames makes SteamVR step in, and its GPU time reads half as much again.
- **Shading is ~40% of a frame at the shell's edge**, ~1.9 of 4.7 ms: the 6 screen derivatives (`dsx`/`dsy`) ~0.55 ms, atan/asin ~0.25, and the rest because near the throat one group of pixels holds both skies, the floor and objects and runs every branch. Godot's own cost (a one-colour shader) is 0.8 ms.
- **144 Hz and SteamVR's half rate.** At 144 Hz (6.9 ms) our edge frame reads 3.4-4 ms and holds,
  but one late frame sends SteamVR to every 2nd refresh for 6-14 s: it then fills in frames on
  the same GPU, and our frame at the same pose reads 5.7-6.3 ms (at 120 → 60 Hz, 7-8 ms even at
  the start, where it costs 2.6). It came back by itself once the frame got cheaper (looking away
  from the throat: 4.7 ms trapped) or on a rate switch (120 and back to 144). More often in
  world B: its boxes have no early out (tour: -5 m 4.04 ms, +5 m 3.72). The Steam overlay drops
  the rate too (it draws on the GPU while open). The app can't stop SteamVR doing it; cheaper
  frames make it rarer. It happens every time in world B at 5.5-6 m facing the throat (4.5-5 ms,
  single frames up to 6); 120 Hz holds there.
- **Waves of 128 gained nothing in the headset:** 12 registers (waves of 128) against 13 (waves of
  64) were 1.6% slower with the same changes; the fillet table gained 0.21 ms at the edge.
- **`inversesqrt` rounding:** |w| from `inversesqrt(dot(w, w))` came out above 1 for rays along
  the throat's cylinder (b = rho0 = rmin), and they took the fillet's branch: cyan specks on the
  throat's circle. `min(dot(w, e2), 1.0)` fixes it; the image diff against main caught it.
- **SteamVR's camera view** (when it shows the outside cameras) takes ~3 ms of GPU a frame: our 4.8 ms frame then reads ~8 ms, and at 120 Hz the headset falls to every 2nd refresh for seconds. 120 Hz that survives it needs ~3.5 ms at the edge.
- **`adreno_stats.sh --disasm`** dumps the biggest program, Godot's generic ubershader (with its decal loop and its own derivatives), not the specialised one that runs. `KEEP_LOG=file` keeps the whole log; `--shader res://...` compiles another ray tracer (set before the first draw, so only it is compiled).
- **Where the edge frame goes (model, main):** curved-region setup ~44%, the flat trace after the
  shell ~25%, shading ~22% (+ derivatives); a third of the issued cycles are nops of dependent
  chains (polynomials at the shader's tail have nothing to overlap with). No block above ~12%.
- **Branches that skip work lose:** a bounding-ball test before each box and shared sphere tests
  for both worlds were slower in the model (the branch and its divergence cost more than the tests
  skipped), as bounding balls were in the headset.
- **16-bit math:** Turnip compiles `mediump` as 16-bit (`mediump_16bit_alu`); in waves of 128 it
  runs at double rate (Mesa `ir3.c`). For the sky's colours the conversions cost more than they
  saved. Line coordinates need float32 anyway.
- **The fillet table:** e(b) has a 1/sqrt(mx) factor that goes to zero like a square root at
  b → Rout; interpolating e itself erred 0.3°, e·sqrt(mx) (put back per pixel) 1e-5 rad. One row
  per regime: the regime comes from the row, so the moments match the table. Turnip filters
  RGBA32F linearly (not on A702); sample with `textureLod` (no implicit derivatives).
- **GDScript's `Vector2/3/4` are single precision** (`float` is double). An ODE integrated in
  `Vector2` and a `PackedVector2Array` table made the gravity's second derivative noisy at 10⁻³
  (`physics`); keep such states in plain floats or `PackedFloat64Array` (`gravity_f` returns one).
- **A view's code costs its shader even when off.** The gravity arrows (a crossing carried through
  the trace) took the shader from 12 to 16 registers (waves of 64); with one shader for the floor
  view and the arrows, switched by a uniform, the floor view cost 3.94 ms by the model, as its own
  shader 3.68 (`main` 3.51).
- **The fog's path length** only needs ~5%: r²/b × psi with r at the weight's mean tau is within
  1.5% here; dropping the exact polynomial took the plain shader from 13 to 12 registers.
