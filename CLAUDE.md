# Notes for agents working on this repo

README.md (Russian) says what the project is, the buttons, how to run, install and check it, and
the one-eye check. `docs/` holds what the code can't say: the method's maths (`geometry.md`), the
gravity's (`gravity.md`) and the owner's wishes (`wishlist.md`). How each part works is in the
comment at the top of its file. This file is how to work here: the owner's rules, the branches,
what a change has to fit, the commands, and facts that cost time to find.

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
  in the headset is a simple yes/no they can see, like the one-eye check (README.md).
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
- **Docs don't retell the code.** What a file does is written in the comment at its top, next to
  the code. README and `docs/` hold only what the code can't say: what the project is, how to run,
  install and check it, the maths, the wishes.
- **A number's source, by its meaning.** Before writing a number, check what exactly the counter,
  test or tool measures and in what unit, not only that it prints that number.
- **"Done" after a cold read.** Before calling docs done, have an agent without this chat's context
  read them and check every statement against the code; fix what it finds and repeat until a read
  finds nothing substantive.
- **Don't anchor on what is already here.** The code and what the docs say about it are how things
  are done now, not how they must be done. Look for the best way as if starting fresh and take it
  even if it replaces what exists, up to writing the project anew. Break and migrate freely: nothing
  is kept for compatibility; carry along everything that depends on a change in the same branch and
  migrate whatever is stored. The checks below still apply.
- **A rule in the way:** if one of these rules gets in the way of the work, say so to the owner and
  propose a replacement; don't work around it silently, and don't change a rule without them.
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

The comment at the top of each file says what it does and what a change to it must keep; read it
for every file you change, and main.gd's: the parts, the order of a frame, the rules for a new
button. The buttons themselves are README's table.

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
| `tools/test_stereo.sh` | the stereo suite (its header); renders in parallel, one Godot per core | ~5 min alone in the cloud, more beside other runs, ~half an hour on the Frame |
| `tools/test.sh [name...]` | the Godot tests `godot/tests/<name>_test.gd`, `JOBS` at a time (one per core), each in its own xvfb; logs in `/tmp/wormhole-tests` | 1–3 min |
| `tools/test_openxr.sh` | the app through OpenXR under Monado (`tests/openxr_smoke.gd`) | ~3 min |
| `tools/fdm_check.sh` | foveation as the Frame's driver applies it | ~10 s |
| `tools/export.sh [--check] [label]` | the build; `--check` turns on the stereo check scene (an empty `godot/check` during the export, `main.CHECK_FLAG`); on the Frame the file is replaced at once, a running build keeps the old one | ~40 s |
| `python3 ref/test_gpu.py` | the shader against the float64 reference, errors per pose | ~4 min |
| `python3 ref/test_fast.py`, `test_eye.py`, `test_slice.py`, `test_gravity.py` | the method, the eye's step, the arrows' surface, gravity against RK4 / a grid | seconds to minutes |
| `tools/adreno_stats.sh [scene]` | the headset's compiler on the shader: instructions, registers, waves | seconds |
| `python3 tools/ir3_live.py LOG` | live registers along the program, the peak and its code | seconds |
| `python3 tools/same_programs.py A.log B.log` | whether two compiler logs hold the same ray-tracer programs | seconds |
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
  the compiled shader (comments, a dead `#ifdef`) must give the same programs byte for byte: compare
  two `KEEP_LOG=file tools/adreno_stats.sh plain --shader res://shaders/<variant>.gdshader` logs
  with `tools/same_programs.py`, one variant at a time. Use a scene without toys: with toys
  `Tracer.set_objects` swaps in `wormhole_balls` and the plain shader after the first frame, the log
  holds their programs too, and `adreno_cost.ray_program` (the smallest `/1` program of at least
  half the biggest) then picks `wormhole_balls`'s. After every change to the shader or the
  emulator run `tools/adreno_cost.sh --check`. Pictures against another commit:
  `tests/emu_dump.gd` at many poses, then diff the PNGs.
- **Driver tools without a GPU** (`adreno_stats.sh`, `adreno_cost.sh`, `fdm_check.sh`): Godot on
  Turnip over Mesa's noop drm-shim (`tools/.bin/mesa-fd`). Godot compiles the ray tracer twice, a
  generic ubershader and then the specialised program that runs (`adreno_cost.ray_program` picks
  it from a log of one shader). Turnip's tiling autotune picks by samples the drm-shim makes up:
  `TU_DEBUG=gmem` tiles wherever possible. `ir3_live.py` counts half registers two to a full
  component and leaves out the shared ones (r48-r55).
- **The cost model** is fitted on the headset's speed check: compare variants with it, then measure
  the best in the headset. It knows no memory waits, and it underrates the toys' shaders and world
  B's outer edge. `--split` models the stencil split, `--hands` / `--held` give each pose its own
  uniforms; the UBO layout `adreno_cost.UNIFORMS` follows the view include's order.
- **The headset's speed check** (`godot/bench.gd`): `bench:`, `tf` and `tour:` lines in the log,
  `refresh:` every second. Frame times from walking around don't compare
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
- **SteamVR on the Frame** shows a non-Steam app's window on a virtual screen in the headset: XR
  renders into a SubViewport and the window shows only a notice. While its dashboard is open the
  app gets no input.
- **Refresh rate.** The app starts at 72 Hz until the menu stores a rate for it. SteamVR answers
  `XR_FB_display_refresh_rate` with success and ignores it; it follows
  `steam.app.<SteamAppId>.preferredRefreshRate`, set by `/opt/steamvr/bin/linuxarm64/vrcmd`, and the
  running app switches within a second (SteamVR 2.18.2). No `XR_EXT_performance_settings`. The GPU
  stays at its top clock (903 MHz) while frames are late.
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
  lines; that it takes our Frame profile is not confirmed in the headset.
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
- **A method named like a native one** (`set_scale` on a Node3D) is a parse error: GDScript's
  NATIVE_METHOD_OVERRIDE warning is an error by default.
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
  still costs (hence a shader per combination: tracer.gd); a loop with a constant bound and `break`
  is unrolled. Registers per pixel set the waves: 48 → 4, 24 → 8, 16 → 12; at 12 or fewer the
  waves are 128 pixels wide.
- **ir3 turns an `if` into selects,** even around a square root: every lane pays. A loop of one pass
  with a bound it can't see (`k < 1 + min(wh_nBall, 0)`) stays a branch that waves skip; the same
  trick stops unrolling (`k < 4 + min(wh_nCube, 0)`).
- **ir3 doesn't hoist loop-invariant code but merges equal expressions:** a value computed before
  a loop is held through it; computed again where it is used, from values held anyway, it is not.
- **Branches that skip work lose** when their divergence costs more than the work (a bounding ball
  before each box).
- **Derivatives** exist only in uniform control flow. A screen derivative costs about as much as
  90 ALU cycles (the cost model's fit).
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

The ray tracer's numerics: the lessons sit in the shader's and wormhole_space.gd's comments where
they apply (float32 cancellation round the throat, the turning point's 0/0, `inversesqrt` above
1, the table's square-root factor, chords not samples, the path length's estimate). Cases a test's
poses may miss: a pose at an odd width (the middle column has vl = 0) and viewpoints scanned
around an object.

Tests:
- **Render scale and the stereo test:** below 100% the bilinear upscale shifts `tools/compare`'s
  one-colour threshold by tenths of a pixel: test a scale with `SCALING_3D_MODE_NEAREST`.
- **The one-eye check in the headset** catches what only the real device shows: ask for it after
  any change to rendering.
