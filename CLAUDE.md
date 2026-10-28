# Notes for agents working on this repo

README.md (Russian) says what the project is, what it does, the buttons and how to build and
check it; `docs/` has the details by topic: `geometry.md`, `rendering.md`, `physics.md`,
`steam-frame.md`, `checks.md`, `wishlist.md`. This file is how to work here: the owner's rules,
the branches, what a change has to fit, the commands, and facts that cost time to find.

## The owner's rules

- **The owner** (GitHub `pomid0rko0`) speaks Russian; answer in Russian.
- **Their setup:** a Valve Steam Frame (standalone VR headset, SteamOS), a Windows 11 PC and an
  Android phone on one Wi-Fi (often the phone's hotspot). SSH into the Frame works with a password.
- **Where you run:** on the Frame itself, in a VSCodium outside Flatpak (`~/Applications/VSCodium`;
  inside the Flatpak `flatpak-spawn --host` is refused), or in a cloud session (an Ubuntu container,
  no headset). The owner wears the headset while you work. The commands are the same in both
  places: the tools find out where they run.
- **Builds:** `tools/export.sh` puts the build where the headset takes it: on the Frame
  `~/wormhole-vr/wormhole_vr.arm64`, one entry in the Steam library, which the owner starts; in a
  cloud session `godot/build/wormhole_vr_<label>_steam_frame.zip`: attach it to the chat, the owner
  installs it with `tools/deploy_frame.bat`. Say what to look at. **Never start the app, SteamVR,
  `vrcmd` or any window yourself:** it takes the view the owner is in.
- **The owner can't judge test images or numbers.** Verifying is your job. Whatever they must check
  in the headset is a simple yes/no they can see, like the one-eye check (`docs/rendering.md`,
  «Сцена проверки стерео»).
- **Tests stay off the headset.** Its GPU, display and SteamVR are the owner's view: a Godot started
  on the Frame's host takes SteamVR as its OpenXR runtime and, through gamescope's Vulkan layer,
  opens windows on the owner's screen. On the Frame everything that runs Godot or opens a GPU runs
  in `tools/box.sh`'s container (lavapipe, xvfb, Monado's simulated runtime, only the repository
  mounted). The tools go there by themselves (`tools/env.sh`, `ref/in_box.py`); a command of your
  own goes through `tools/box.sh` (`tools/box.sh godot --headless --path godot --import`), which in
  a cloud session runs it in place. Never start `tools/.bin/godot` on the Frame without it.
- **One wish per chat,** on a branch you name yourself: a short English word (`throat`, `grab`),
  started from the branch listed below for the wish. Don't use the session's `claude/…` branch; the
  owner allows pushing to the branch you name.
- **Versions are git tags,** set by the owner on a commit they checked in the headset.
- **Docs say what is true now.** README, `docs/` and code comments describe the code as it is: no
  history (git and the PRs keep it), no versions, numbers only as measured on the current code (the
  doc names the tool or test that gives them). A change that makes a statement or a number stale
  fixes or removes it in the same branch.
- **Don't anchor on what is already here.** The code and what the docs say about it are how things
  are done now, not how they must be done. Look for the best way as if starting fresh and take it
  even if it replaces what exists, up to writing the project anew. Break and migrate freely: nothing
  is kept for compatibility; carry along everything that depends on a change in the same branch and
  migrate whatever is stored. The checks below still apply.
- **Long runs in the background, the build at once.** The owner checks builds while the tests run
  and doesn't wait for them, not even for the stereo test. Once the code for a build is in place:
  start `tools/test_stereo.sh` in the background, export and deliver the build, say the tests still
  run. Every other run of minutes goes to the background too; report and fix what it finds
  afterwards. A run reads the code from disk while it goes: commit first or run it from a
  `git worktree`, and don't edit `godot/` under it.

## Hard rule: stereo before headset

Broken stereo physically hurts in a headset. Every headset build gets `tools/test_stereo.sh` on
exactly its source, and it must pass (exit 0). The owner may take the build before the run ends: the
moment it fails, tell them at once not to put that build on, then fix it. Anything Godot draws next
to ray-traced things must line up the same way, and the stereo test must check it.

## Branches

`main` is what the owner checked in the headset (a tag marks the commit). Each wish gets its own
branch from the one listed here, so each can be checked alone.

Open, each with a PR into `main`:
- `strength` (PR #16): the hand of finite strength, the grip by size, two hands as one rig;
- `rim` (PR #17): cheaper frames with toys at the shell's edge, cubes at the edge, the speed check
  over scenes of play;
- `lean` (PR #18): the toys in passes of their own, culled before the search; overlaps `rim`;
- `rethink` (PR #20): research only (`research/`): per-eye ray tables, a bounded object search;
- `throat` (no PR, older than the current ray tracer): the right stick's y changes the throat's
  length, with the right grip held the fillet, A resets (`tests/throat_test.gd`); to be redone on
  `main`.

`strength`, `rim` and `lean` predate the split of `main.gd` into its parts: merging one moves its
changes to where that code lives now (the table in PR #23). Every other branch is merged or an old
sketch: don't start from it.

Where the wishes (`docs/wishlist.md`) start:
- the hand of finite strength → `strength`; pulling objects as in Half-Life: Alyx → `main`
  (`hands.gd`), or `strength` while it is open;
- cheaper frames with toys, 144 Hz → `rim`, `lean` or `rethink`: ask the owner which;
- throat shape, knobs, test scenes → `throat`'s idea, redone on `main`;
- everything else → `main`. Several wormholes, portals and other shapes are renderer work:
  `wormhole_core` and a reference in `ref/` first. An avatar's head ball is a candidate for every ray
  inside the throat: it needs a cheaper toys' search first. The owner wants no automatic way out of
  SteamVR's half rate for now.

## What a change has to fit

The scripts (`godot/`): `main.gd` the scene and the viewer (feet on the floor, the room's axes
carried there, the head above them), walking, turning, the reset, the order of each frame;
`tracer.gd` the ray tracer's quads, shader variants, uniforms, toys and stencil split; `toys.gd` the
demo over `ball_world.gd`'s physics; `hands.gd`; `foveation.gd` with `split_pass.gd`; `menu.gd`;
`frame_rate.gd` with `rate_meter.gd`; `bench.gd` the speed check; `check_scene.gd`;
`wormhole_space.gd` the geometry and gravity on the CPU; `scene.json` the static objects.

- **Buttons.** The grip grabs; right B and left X (the Frame's D-pad down) make a new ball / cube;
  left Y (the D-pad up, left, right) steps the gravity view; A resets everything (a new reset joins
  it); the left trigger runs; the right stick's x turns, its click switches smooth/snap. Nothing is
  pointed at with the triggers.
- **The action map** (`openxr_action_map.tres`) binds only what the app reads, in the Frame's
  profile, KHR generic, Touch and eye gaze; `tests/util.gd` `BINDINGS` is the same table and the
  tests compare them exactly. A new action goes into both, in the Frame profile with Valve's paths.
  Left X / Y of the other profiles are the Frame's D-pad down / up, left, right.
- **The menu.** While it is open (`main.menu_active`, including the frame that closes it) A, B, the
  D-pad and the left stick are its; a new button checks it and stays off the left stick's click,
  View and Menu. A setting is a row: `Menu.ROWS`, `_count`, `_current`, `_apply`, `_value_text`.
- **The speed check** sets the viewer's pose itself: while it runs (`main.hold`) the sticks, A and
  the hands do nothing, and a new button stays out too; the menu greys the rows it sets.
- **The hands** take two of the shader's 12 ball slots (`BallWorld.MAX_BALLS` 8 + 2). Each frame
  the free toys step first (pushed from the hands' last places), then the hands and what they hold
  are placed (`Hands.update`), then everything is drawn: a toy let go starts from the hand. Jumps of
  the viewer (`place`, `set_pose`, a snap turn) call `Hands.forget_motion`, or the jump is a throw.
- **A throat change** (`space.set_profile`) rebuilds what is built for the shape:
  `tracer.upload_fillet_table()` (slow in GDScript: not per frame), `tracer.upload_gravity()`,
  `set_objects` (its sorting and proxies use `space.h`, `space.Rout`). Balls keep their distance to
  the shell's edge, as the feet do.
- **Foveation and the render scale:** one of them at a time (the eye-tracked offsets are in
  full-size pixels). The split pass sits on the XR camera's compositor: an effect added there
  splits the pass too.
- **The stencil split:** two materials, `tracer.material` with the toys and `plain_material`
  without. A uniform both read goes through `tracer.param`; the toys' own (`wh_ball`…) only to
  `material` (`set_objects`). A ball's shader index is not its index in `world.balls`
  (`set_objects` sorts them). Godot geometry drawn before the ray tracers must not write the
  stencil. Toys in the hand are fine: a ray that meets a toy leaves its proxy at least the margin
  (8 cm, more than the near plane's 5 cm) before the hit.

## Commands

The cloud session is set up already: run `tools/setup.sh` once at the start, which only links
`tools/.bin` to the environment's install in a second or two. Install nothing by hand (apt, pip,
Godot, Mesa); if `setup.sh` starts downloading or building, the environment lacks something: tell
the owner which step. On a fresh machine it downloads and installs everything; on the Frame all of
it goes into `tools/box.sh`'s container (made on first use in minutes, then kept). `tools/box.sh CMD`
passes the tools' variables (`JOBS`, `OUT`, `GODOT`, `MESA`, `KEEP_LOG`, `WH_*`) and nothing else
(`tools/box.sh env VAR=... CMD` for others). `tools/setup.sh godot templates` runs only the steps
named. A tool you had to install goes into `setup.sh`.

| command | what | time |
|---|---|---|
| `tools/test_stereo.sh` | the stereo suite (`docs/checks.md`); renders in parallel, one Godot per core | ~5 min alone in the cloud, more beside other runs, ~half an hour on the Frame |
| `tools/test.sh [name...]` | the Godot tests `godot/tests/<name>_test.gd`, all at once, each in its own xvfb; logs in `/tmp/wormhole-tests` | 1–3 min |
| `tools/test_openxr.sh` | the app through OpenXR under Monado (`tests/openxr_smoke.gd`) | ~3 min |
| `tools/fdm_check.sh` | foveation as the Frame's driver applies it | ~10 s |
| `tools/export.sh [--check] [label]` | the build; `--check` turns on the stereo check scene (an empty `godot/check` during the export, `main.CHECK_FLAG`); on the Frame the file is replaced at once, a running build keeps the old one | ~40 s |
| `python3 ref/test_gpu.py` | the shader against the float64 reference, errors per pose | ~4 min |
| `python3 ref/test_fast.py`, `test_eye.py`, `test_slice.py`, `test_gravity.py` | the method, the eye's step, the arrows' surface, gravity against RK4 / a grid | seconds to minutes |
| `tools/adreno_stats.sh [scene]` | the headset's compiler on the shader: instructions, registers, waves | seconds |
| `python3 tools/ir3_live.py LOG` | live registers along the program, the peak and its code | seconds |
| `tools/adreno_cost.sh [opts] [source...]` | the frame-cost model at the speed check's poses | ~1 min per source |
| `tools/ab_shaders.sh [--auto] source...` | other ray tracers into the build for the headset's speed check | seconds |

- **Godot tests.** A test's header has its run line (`##   godot <flags> -s res://tests/<name>_test.gd`);
  `tools/test.sh` takes its flags from there, so a new test needs one. Tests share `tests/util.gd`:
  `U.check` prints `PASS name` / `FAIL name  detail`, `U.finish` prints `FAILURES: n`, takes a
  simulated headset down (left up, it aborts Godot at exit with status 134) and quits 1 on any
  failure; also keys, `U.headset`, `U.controller`, `U.save_eyes`. `main._ready` has not run during a
  test's `_initialize`: set main's fields there (`main.toys.enabled`, `main.xr_name`,
  `main.show_check`), touch its nodes from `_process`, frame 2 or later.
- **Script classes.** The tools import the project when `godot/.godot` is missing. After adding a
  `class_name`, or before a Godot run of your own with `-s`, run
  `tools/box.sh godot --headless --path godot --import`.
- **Monado** (`test_openxr.sh`): while `monado-service` runs, any Godot here connects to it as a
  headset, so it never runs beside `test_stereo.sh` or `tools/test.sh`. Its stdin must be a pipe or
  FIFO (on `/dev/null` it quits at once). Its null compositor offers one rate, 20 Hz, 128×128 per
  eye, and reading eye images back fails there: images come from `fake_hmd.gd` or "Native mobile".
  Its simulated controllers bind to none of our profiles and it has no Frame profile: controller
  input in tests comes from `XRControllerTracker`s set by hand (`U.controller`).
- **Shader changes.** `test_gpu.py` prints errors, no verdict: compare with the same run on the code
  before the change (`WH_BALLS=0` too: the shader without balls). `ref/wh.py` `fast` mirrors the
  shader's curved-region method in float64: keep the two in step. A change that should not touch
  the compiled shader (comments, a dead `#ifdef`) must give the same program byte for byte: compare
  two `KEEP_LOG=file tools/adreno_stats.sh` logs with `adreno_cost.ray_program`. After every change
  to the shader or the emulator run `tools/adreno_cost.sh --check`. Pictures against another commit:
  `tests/emu_dump.gd` at many poses, then diff the PNGs.
- **Driver tools without a GPU** (`adreno_stats.sh`, `adreno_cost.sh`, `fdm_check.sh`): Godot on
  Turnip over Mesa's noop drm-shim (`tools/.bin/mesa-fd`). Godot compiles the ray tracer twice, a
  generic ubershader and then the specialised program that runs (`adreno_cost.ray_program` picks
  it). Turnip's tiling autotune picks by samples the drm-shim makes up: `TU_DEBUG=gmem` tiles
  wherever possible. `ir3_live.py` counts half registers two to a full component and leaves out the
  shared ones (r48-r55).
- **The cost model** is fitted on the headset's speed check: compare variants with it, then measure
  the best in the headset. It knows no memory waits, and it underrates the toys' shaders and world
  B's outer edge. `--split` models the stencil split, `--hands` / `--held` give each pose its own
  uniforms; the UBO layout `adreno_cost.UNIFORMS` follows the view include's order.
- **The headset's speed check** (`docs/steam-frame.md`, «Замер скорости»): `bench:`, `tf` and
  `tour:` lines in the log, `refresh:` every second. Frame times from walking around don't compare
  between builds: where one looks changes them several times.
- **GitHub:** on the Frame git pushes as the owner through `gh` (`~/.local/bin/gh`,
  `gh auth setup-git`), commits as `Claude <noreply@anthropic.com>` (the repository's git config).
  In a cloud session branch pushes go through the session's proxy and tag pushes are refused. The
  owner creates tags on GitHub.

## Facts that cost time to find

Godot, SteamVR and the Frame:
- **Multiview.** `INV_VIEW_MATRIX` is a camera shared by the eyes; each eye's offset and rotation
  are in its `PROJECTION_MATRIX`; `EYE_OFFSET` is the eye in that view space. Rays start at the eye:
  from the head's centre the eyes look in different directions.
- **A pixel's ray comes from the screen's corners,** never from its screen position: exact under
  any density map (a coarse pixel gets the ray through its centre).
- **The stereo check's chart → room map** is computed at placement, recentre and stick moves and
  turns, never every frame from the feet: so it is fixed to the room and drift shows.
- **SteamVR on the Frame** shows a non-Steam app's window on a virtual screen in the headset: XR
  renders into a SubViewport and the window shows only a notice. While its dashboard is open the
  app gets no input.
- **Refresh rate.** The app starts at 72 Hz. SteamVR answers `XR_FB_display_refresh_rate` with
  success and ignores it; it follows `steam.app.<SteamAppId>.preferredRefreshRate`, set by
  `/opt/steamvr/bin/linuxarm64/vrcmd`, and the running app switches within a second (SteamVR
  2.18.2). No `XR_EXT_performance_settings`. The GPU stays at its top clock (903 MHz) while frames
  are late.
- **Half rate.** One late frame sends SteamVR to every 2nd refresh for 6–14 s; it fills in frames
  on the same GPU, our frame at the same pose costs more, and it can stay there until the frame
  gets cheaper or the rate is switched there and back. The Steam overlay and SteamVR's camera view
  do the same. The app can't stop it; cheaper frames make it rarer.
- **Foveation in Godot 4.7.2 on Turnip.** The density map applies per tile, only in tiled passes;
  Turnip renders a pass without tiles if a subpass dependency lacks `VK_DEPENDENCY_BY_REGION_BIT`,
  and Godot 4.7.2's two-subpass pass at 100% has one (godotengine/godot#124141, fixed after
  4.7.2): `split_pass.gd` (an empty POST_TRANSPARENT CompositorEffect) splits it. Subsampled
  images are off (SteamVR can't read them). Godot asks for the eye-tracked offsets only with
  `xr/openxr/extensions/eye_gaze_interaction` on, in full-size pixels. The swapchain gets a density
  map only if `foveation_level` > 0 at creation (`project.godot` asks for 3; "off" is `vrs_mode`
  disabled). No shading-rate VRS on the Frame: the sharp zone is whole tiles. Our map is a
  `Texture2DArray` set with `RenderingServer.viewport_set_vrs_texture` and `VRS_UPDATE_ALWAYS` (a
  buffer rebuild leaves the driver's map empty otherwise). Godot maps a colour c to density 1 - c,
  Turnip a density d to 1/d floored to a power of two: 4x is byte 192 (191 gives 2).
  `verbose_stdout` lists the extensions and the driver's support (hundreds of lines: keep it off).
- **Controllers.** Godot 4.7.2 knows the Frame's profile (`/interaction_profiles/valve/frame_controller_valve`).
  Valve's page «Steam Frame Input» lists its paths: left `dpad_up/down/left/right`, `view`,
  `system`, `bumper`; right `a`, `b`, `x`, `y`, `menu`, `system`, `bumper`; both `squeeze`,
  `trigger`, `thumbstick`, `grip/pose`, `aim/pose`, `output/haptic`. SteamVR takes the Frame profile
  if the app offers it, else generic, else Touch remapped (Touch's menu is View, its upper button
  all three upper buttons). One path a runtime rejects drops the whole profile (Monado rejects
  `grip_surface/pose` on Touch). Which profile SteamVR gave shows in the log's `interaction profile`
  lines; that it takes our Frame profile has not been seen in the headset yet.
- **OpenXR interface signals:** connect a method callable, not a GDScript lambda (a lambda corrupts
  the heap at exit under Monado). `tools/test_openxr.sh` fails on a crash at exit.
- **Godot on the Frame's host** connects to SteamVR unless `XR_RUNTIME_JSON` points elsewhere;
  gamescope's Vulkan layer puts its swapchains on the owner's screen even under xvfb-run; without
  the layer Turnip finds no queue that presents to Xvfb; there is no lavapipe.
- **Logs** on the Frame: `~/.local/share/godot/app_userdata/Wormhole VR/logs/` (from the PC
  `tools/frame_logs.bat`). Screenshots (`tools/frame_screens.bat [days]`) are 1920×1080 JPEGs of
  one eye, in `userdata/<id>/760/remote/<64-bit game id>/screenshots`.
  `application/run/flush_stdout_on_print` stays on: an export otherwise buffers `print()` and an
  abort at exit loses the log.
- **Sysfs files** claim 4096 bytes and `FileAccess.get_file_as_string` reads them all: read them
  with `get_line()` (`FrameRate.read_line`).
- **GDScript's `Vector2/3/4` are single precision** (`float` is double): keep ODE states and tables
  in floats or `PackedFloat64Array`.
- **A method named like a native one** (`set_scale` on a Node3D) is a parse error: the project
  treats warnings as errors.
- **The stencil** (`stencil_mode read|write, compare_..., ref`) works on Mobile, multiview and
  lavapipe. Opaque draws follow `render_priority`, lower first. A MeshInstance3D whose
  ShaderMaterial has no shader yet is drawn with Godot's default lit material, a huge program:
  create such a node only once its shader is known.
- **Shader constants** are printed with 14 decimals: `1e-20` becomes 0.0, `1e-12` survives. GPUs'
  `max`/`min` return the other operand for a NaN, which hides most NaNs.
- **The shading language** reserves `E`, `PI`, `TAU`: a local `E` is a compile error that GLSL
  (`ref/`) accepts.

The Adreno 750 and its compiler (ir3):
- **Measure in the headset.** Fewer instructions or fewer registers are not faster by themselves.
  Compare variants with the speed check at 72 Hz: a variant over the frame's budget halves the
  rate and reads dearer than it is, and so does the segment after it.
- **Registers go to the heaviest point of the code, run or not:** code for something not in view
  still costs. Hence one shader per combination (`WH_NO_BALLS`, `WH_GRAVITY`, `WH_ARROWS`), loops
  over objects bounded by `wh_nBall` (a constant bound with `break` is unrolled), candidates as bit
  masks. Registers per pixel set the waves: 48 → 4, 24 → 8, 16 → 12; at 12 or fewer the waves are
  128 pixels wide.
- **ir3 turns an `if` into selects,** even around a square root: every lane pays. A loop of one pass
  with a bound it can't see (`k < 1 + min(wh_nBall, 0)`) stays a branch that waves skip; the same
  trick stops unrolling (`k < 4 + min(wh_nCube, 0)`).
- **ir3 doesn't hoist loop-invariant code but merges equal expressions:** a value computed before
  a loop is held through it; computed again where it is used, from values held anyway, it is not.
- **Branches that skip work lose** when their divergence costs more than the work (a bounding ball
  before each box).
- **Derivatives** exist only in uniform control flow: `wh_renderE` computes the lines' coordinates
  for every pixel and their derivatives once, after the trace. A screen derivative costs about as
  much as 90 ALU cycles.
- **Near the throat** one group of pixels holds both skies, the floor and objects, and runs every
  branch of the shading.
- **16-bit math** (`mediump`) runs at double rate in waves of 128, but conversions cost more than it
  saves for the sky's colours; line coordinates need float32.
- **Uniform arrays at a computed index** compile to `mova a0.x` + `c<a0.x + N>` (a0.x counts
  components). a7xx's `shlm`/`shrm`/`shlg`/`shrg` take the shift amount first (Mesa
  `isa/ir3-cat3.xml`).
- **Program N/2** (a shader with more than 100 vec4 of constants compiled again to read them from
  memory) runs only if the stages need more than 512 vec4; ours need about 200, so N/1 runs.
  `adreno_stats.sh --disasm` dumps the biggest program, the generic ubershader, not the one that runs.
- **Software-Vulkan timings** are good for ratios only, not for the shader's inner costs.

The ray tracer's numerics:
- **The fillet table** stores e·sqrt(mx), not e: e has a factor 1/sqrt(mx) that goes to zero like a
  square root at b → Rout, which interpolation misses; the pixel puts sqrt(mx) back. One row per
  regime, so the moments match the table. Sample it with `textureLod`.
- **Rays that go round the throat** (|vl| tiny on the cylinder, looking sideways inside it) lose
  float32 digits: 1 - wc² is (rho0 - b)(rho0 + b) with rho0 - b from vl², and hit keys carry no large
  offsets. Test such rays with a pose at an odd width (the middle column at vl = 0).
- **A turning ray's turning point** has t = z = zlo = 0 in `wh_filMom`: the expression there
  must stay finite (`z - zlo`), here and in `ref/wh.py`; a NaN poisons the rest of the ray. Scan
  viewpoints around an object when a test's poses may miss a corner case.
- **`inversesqrt` rounding** gives |w| above 1 for rays along the cylinder (b = rho0): clamp
  `min(dot(w, e2), 1.0)`.
- **The fog's path length** needs ~5%: r²/b × psi with r at the weight's mean tau. The toys' hits
  are ordered by place on the path (piece + fraction), not by length.
- **Moving objects in the curved region: chords, not samples.** Between two samples the chord in
  R⁴ is tested against each object, and the path's point at the chord's entry is the hit if it lies
  within the chord's sag. Objects cost per ray: each is searched only where the path is within
  reach in r and w, and on a fillet in its psi window (`wh_filSolve`); a ball at the eye or in the
  throat is a candidate for many rays, a ball far from the throat must not be one.
- **Render scale and the stereo test:** below 100% the bilinear upscale shifts `tools/compare`'s
  one-colour threshold by tenths of a pixel: test a scale with `SCALING_3D_MODE_NEAREST`.
- **The one-eye check in the headset** catches what only the real device shows: ask for it after
  any change to rendering.
