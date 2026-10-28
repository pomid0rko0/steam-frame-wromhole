# Notes for agents working on this repo

Read README.md first (Russian): what the project is, what it does, the buttons, how to build and
check it. The details are in `docs/` by topic: `geometry.md` (the space, the method, its
accuracy), `rendering.md` (the eyes' rays, the toys, the shader variants, the stencil, foveation,
the stereo check), `physics.md` (gravity, balls and cubes, hands), `steam-frame.md` (the headset
and SteamVR, the rate, the menu, the speed check), `checks.md` (the tests and the shader tools),
`wishlist.md`. They say what is true of the code now, with numbers measured on it; no history.

## Who and how

- **The owner** (GitHub `pomid0rko0`) speaks Russian; answer in Russian.
- **Their setup:** a Valve Steam Frame (standalone VR headset, SteamOS), a Windows 11 PC and an Android phone, all on one Wi-Fi (often the phone's hotspot). SSH into the Frame is enabled with a password.
- **Where you run:** on the Frame itself, in a VSCodium outside Flatpak (`~/Applications/VSCodium`; inside the Flatpak `flatpak-spawn --host` is refused and the host is out of reach), or in a cloud session (an Ubuntu container, no headset). The owner works in the headset, wearing it while you work. The commands in this file are the same in both places: the tools find out where they run.
- **How builds reach the headset:** `tools/export.sh` exports the build and puts it where the headset takes it. On the Frame that is `~/wormhole-vr/wormhole_vr.arm64`, already in the Steam library as one entry; the owner starts it from there and tells you what they see. In a cloud session it is `godot/build/wormhole_vr_<label>_steam_frame.zip`, which the owner puts on the Frame with `tools/deploy_frame.bat` from the PC. Never start the app (or SteamVR, `vrcmd`, any window) yourself: it takes the view the owner is in.
- **The owner can't judge test images or numbers.** Verifying is your job. Anything they must check in the headset has to be a simple yes/no they can see, like the one-eye check (`docs/rendering.md`, «Сцена проверки стерео»).
- **The headset is in use: tests stay off it.** Its GPU, display and SteamVR are the owner's view. A Godot started on the host takes SteamVR as its OpenXR runtime (`~/.config/openxr/1/active_runtime.json`) and, through gamescope's Vulkan layer, opens windows on the owner's screen. So on the Frame everything that runs Godot or opens a GPU runs in `tools/box.sh`'s Ubuntu container: software Vulkan (lavapipe), xvfb, Monado's simulated OpenXR runtime, only the repository mounted, no GPU, no display, no SteamVR; on the CPU cores Steam gives desktop apps. The tools go there by themselves (`tools/env.sh`; the Python checks and tools by `ref/in_box.py`). A command of your own that starts Godot or opens a GPU goes through `tools/box.sh` (`tools/box.sh godot --headless --path godot --import`), which in a cloud session runs it right there. Never start `tools/.bin/godot` on the Frame without it. `godot/tests/fake_hmd.gd` is a scripted headset through Godot's real multiview path.
- **One wish per chat,** starting from the branch listed below for it.
- **Name the branch yourself.** The session hands you a `claude/<random-name>` branch: don't use it. Name the wish's branch with a short English word (`throat`, `grab`), start it from the branch listed below for the wish, and push there. The owner allows this; it is their standing permission to push to a branch other than the one the session gives you.
- **Versions are git tags,** set on a commit once the owner has checked it in the headset. Don't put versions or a history of builds into docs or comments; git keeps them.
- **Don't anchor on what is already here.** The code, and what the docs and this file say about it, is how things are done now, not how they must be done. For any task, look for the best way as if starting fresh, and take it even if it replaces what exists, up to writing the project anew: nothing stays because it is already there. Break things and migrate, freely and often: nothing is kept for compatibility; carry along everything that depends on a change in the same branch, and migrate whatever is stored to the new form. The checks this file requires apply to what comes out as before.
- **Deliver a build** with `tools/export.sh` (above) and say what to look at. From a cloud session: attach the zip it makes to the chat.
- **Long runs first, in the background; the build at once.** The owner checks builds in the headset while the tests run and does not want to wait for them, not even for `test_stereo.sh`. As soon as the code for a build is in place: start `tools/test_stereo.sh` in the background first, export the build (`tools/export.sh`) and deliver it at once, saying the tests still run. Every other check that takes minutes (`tools/test_openxr.sh` ~3 min, not together with `test_stereo.sh` or `tools/test.sh`: Monado; `tools/test.sh`, the Godot tests, ~1-2 min each; `ref/test_gpu.py` ~4 min) runs in the background too, after or beside it, and what it finds is reported and fixed afterwards. Never sit in the foreground on a run of minutes while the owner waits. A run reads the code from disk while it goes: don't edit `godot/` under it (commit first, or run it from a `git worktree`).

## Branches

Each wish has its own branch from `main`, so each can be checked in the headset alone. `main` is
what the owner has checked in the headset (its tag marks the commit); README.md and `docs/` describe
all of it. How things got there is in `git log` and the PRs.

**Open branches**, each with a PR into `main` that describes it:
- `strength` (PR #16) — the hand of finite strength, the grip by size, two hands as one rig.
- `rim` (PR #17) — cheaper frames with toys at the shell's edge, cubes at the edge, the speed
  check over scenes of play.
- `lean` (PR #18) — the toys in passes of their own, culled before the search; it overlaps `rim`.
- `rethink` (PR #20) — research only (`research/`): per-eye ray tables and a bounded object search.
- `throat` (no PR, from before the fast core) — throat knobs: the right stick up/down changes the
  throat length, with the right grip held the fillet; A resets (`tests/throat_test.gd`). To be
  redone on today's `main`.

`strength`, `rim` and `lean` were made before `main.gd` was split into its parts (below,
«Working on `main`»): merging one means moving its changes to where that code lives now.

**Merged into `main`, or old sketches:** `walking`, `refresh-rate`, `fast-rays`, `edge-120hz`,
`foveation`, `gravity`, `toys`, `throw`, `menu`, `setup`, `anywhere`, `breaking`, `sweep`, the
sessions' `claude/…` and `ccr-…`; the sketches `controls`, `grab`, `physics`. Don't start from them.

Where the wishes (`docs/wishlist.md`) start (wishes without a branch start from `main`):
- free flight in 3D with gravity on/off → `main` (the honest field, `WormholeSpace.potential_grad`,
  and bodies that move in it, `ball_world.gd`);
- the hand of finite strength → `strength`; pulling objects like in Half-Life: Alyx → `main`
  (`hands.gd`), or `strength` while it is not merged;
- cheaper frames with toys, 144 Hz → `rim`, `lean` or `rethink`: ask the owner which;
- the light in the throat, cubes next to balls → `main`;
- throat shape, VR-friendly knobs, test scenes → `throat`, redone on `main`;
- the menu, its rows, controller buttons → `main` (`menu.gd`);
- refresh rate, render scale, cheaper rays near the wormhole → `main` (`wh_curved` in
  `wormhole_core`; measured in the headset by the speed check, without one `tools/adreno_cost.sh`,
  then `tools/adreno_stats.sh`); the owner wants no automatic way out of SteamVR's half rate for
  now; world B's outer edge facing the throat is where the model misses ~1 ms;
- foveated rendering → `main` (the sharp zone is whole tiles, the driver's limit);
- placing wormholes by hand, several wormholes, flat portals, two-handed shooting, gun models,
  other shapes (torus, arbitrary SDF) → `main`; several wormholes, portals and other shapes are
  renderer work (`wormhole_core` and a reference in `ref/` first);
- an avatar: a ball for the head around the eyes is a candidate for every ray inside the throat
  and drops the frame; it needs a cheaper toys' search first.

## Working on `main`

The app's scripts (`godot/`): `main.gd` builds the scene and keeps the viewer (feet on the floor,
the room's axes carried there, the head above them), walking, turning, the reset and the order of
each frame; `tracer.gd` the ray tracer (its quads, shaders, uniforms, the toys it draws, the
stencil split); `toys.gd` the demo's balls and cubes over `ball_world.gd`'s physics; `hands.gd`
grab and throw; `foveation.gd` (with `split_pass.gd`); `menu.gd` the menu, its buttons and the
line below; `frame_rate.gd` (with `rate_meter.gd`) the measured rate, choosing it, the `refresh:`
log; `bench.gd` the speed check; `check_scene.gd` the stereo check; `wormhole_space.gd` the
geometry and gravity on the CPU. What a change has to fit:
- **Buttons.** The grip grabs; right B and left X (the Frame's D-pad down) make a new ball / cube;
  left Y (the D-pad up, left, right) steps the gravity view; A resets everything at once (a new
  reset joins it); the left trigger runs; the right stick's x turns, its click switches
  smooth/snap. Nothing is pointed at with the triggers. `throat` puts the fillet on the right grip
  + right stick y: on `main` the grip grabs, so it needs another way.
- **The action map** (`openxr_action_map.tres`) binds only what the app reads, in the Frame's own
  profile, the KHR generic one, Touch and the eye gaze; `tests/util.gd` (`BINDINGS`) is the same
  table, and the tests check the map against it exactly. A new action goes into both, in the Frame
  profile with Valve's paths (SteamVR takes that profile when the app offers it: an action missing
  there gets nothing; one path it rejects drops the profile). Left X / Y of the other profiles are
  the Frame's D-pad down / up, left, right.
- **The menu.** While it is open (`main.menu_active`, the whole frame that closes it too) A, B,
  the D-pad and the left stick are its: a new button checks it and stays off the left stick
  click, View and Menu. A setting fits the menu as a row (`Menu.ROWS`, `_count`, `_current`,
  `_apply`, `_value_text`).
- **The speed check** (`bench.gd`) sets the viewer's pose itself: while it runs (`main.hold`) the
  sticks, A and the hands do nothing; a new button stays out of it too (the menu greys the rows
  the speed check sets).
- **The hands** take two of the shader's 12 ball slots (`BallWorld.MAX_BALLS` 8 + 2). Per frame
  `main._process` steps the free toys first (the hands pushing from last frame's places), then
  places the hands and what they hold (`Hands.update`), then draws: a toy let go starts from the
  hand, not a frame ahead. Teleports (`place`, `set_pose`, a snap turn) forget the hands' recent
  places (`Hands.forget_motion`), or the jump would be a throw.
- **A throat change** (`space.set_profile`): what is built for the shape is built again:
  `tracer.upload_fillet_table()` (3 ms in GDScript on the desktop), `tracer.upload_gravity()`, and
  `set_objects` (the sorting and the proxies use `space.h`, `space.Rout`). Balls keep their
  distance to the edge of the curved shell, as the feet do.
- **Foveation and the render scale:** the menu lets one of them be on (the eye-tracked map's
  offsets are in full-size pixels). The split pass is on the XR camera's compositor: an effect
  added there splits the pass as well. The action map has the eye gaze profile (`eye_gaze_pose` on
  `/user/eyes_ext`).
- **The stencil split:** two ray tracer materials (`tracer.material` with the toys,
  `plain_material` where none can be seen): a uniform both read goes through `tracer.param`; the
  toys' own (`wh_ball`...) only to `material` (`set_objects`). The shader index of a ball is not
  its index in `world.balls` (`set_objects` sorts them). Godot geometry drawn before the ray
  tracers must not set the stencil. Toys held in the hand are fine: a ray that meets a toy leaves
  its proxy at least the margin (8 cm, more than the near plane's 5 cm) beyond the hit.

## Hard rule: stereo before headset

Broken stereo physically hurts in a headset. For every headset build, run `tools/test_stereo.sh`
on exactly that source; it must pass (exit 0). The owner takes the build before it finishes
(started first, in the background: above), so the moment it fails, tell the owner at once not
to put that build on, then fix it. If you add things Godot draws next to ray-traced ones, check
they line up the same way.

## Running things

- **A cloud session is set up already: install nothing.** The environment's setup script is a copy of `tools/setup.sh`; it ran outside the repo (into `/tools/.bin`, with `godot` in `/usr/local/bin`, the templates in `~/.local/share/godot`, apt and pip in the system), and the cloud keeps that; only the repo is cloned afresh, so its `tools/.bin` is empty. That is not a fresh machine. Run `tools/setup.sh` once at the start: in 1-2 s it links `tools/.bin/godot` and `tools/.bin/mesa-fd` to that install and downloads, installs and builds nothing. Never install by hand (apt, pip, Godot, Mesa) what it covers. If it starts downloading or building, the environment lacks something: tell the owner which step, don't sit it out.
- **Fresh machine:** `tools/setup.sh` downloads Godot 4.7.2 into `tools/.bin` (the machine's build, x86_64 or arm64, linked as `tools/.bin/godot`, the name the tools use, and as `godot` in `/usr/local/bin`), the export templates and the pip packages, and installs xvfb, lavapipe, EGL and Monado with apt if they are missing. `tools/setup.sh godot templates` runs only the steps named. On the Frame (SteamOS: read-only root, no apt) all of it goes into `tools/box.sh`'s container (made on first use, ~5 min, and kept): Godot into the repo's `tools/.bin`, the templates and the rest into the container; the host needs only podman. `tools/box.sh CMD` runs CMD there in the same directory; the tools' own variables (`JOBS`, `OUT`, `GODOT`, `MESA`, `KEEP_LOG`, `WH_*`) go along, nothing else of the host's environment does (`tools/box.sh env VAR=... CMD` for others). A tool you had to install by hand goes into `setup.sh` too.
- **Fresh clone, new script classes:** the tools import the project themselves (`import_once` in `tools/env.sh`, only when `godot/.godot` is missing); before a Godot run of your own with `-s`, and after adding a `class_name`, `tools/box.sh godot --headless --path godot --import`, or the classes (`WormholeSpace`, `Tracer`...) are unknown.
- **Tests:** `tools/test.sh [name...]` runs the Godot tests `godot/tests/<name>_test.gd` (all of them without names) at once, each under xvfb with its own display and user data and with the flags of its header's run line (`##   godot <flags> -s res://tests/<name>_test.gd`: a new test needs one), and prints a line per test with its FAIL lines; logs in `/tmp/wormhole-tests`. On `main`: `gravity` (the field against `ref/test_gravity.py`, Laplace, the shader's polynomials, the views' colours), `physics`, `grab` (the hands, through the simulated headset and controller trackers), `bench`, `refresh_rate` (the rate meter, the verdict, the GPU clock), `walking` / `walking_xr` (the sticks and the menu, from keys and from controller trackers, and the action map against `BINDINGS`); a branch's own the same way (`throat`). The scripts share `tests/util.gd`: `U.check` prints `PASS name` / `FAIL name  detail`, `U.finish` prints `FAILURES: n`, takes a simulated headset down (left up at exit it aborts Godot, status 134) and quits 1 on any; also keys, `U.headset`, `U.controller`, `U.save_eyes`. In test scripts `main._ready` has not run during `_initialize`: set main's fields there (`main.toys.enabled`, `main.xr_name`, `main.show_check`), touch its nodes from `_process` (frame 2 or later).
- **Stereo:** `tools/test_stereo.sh` (~5 min alone in the cloud, ~12 with other tests beside it, ~27 alone on the Frame, whose desktop apps get 5 cores: the renders run in parallel, one Godot per core, each with its own display and shader cache; a render that does not exit 0 within 10 minutes fails it; the check scene again with foveation on, and those pictures against the ones without). Scripts: `desktop_sphere.gd`, `multiview_sphere.gd` (Godot's "Native mobile"), `multiview_hmd.gd` (`balls|cubes` through `fake_hmd.gd`), `multiview_check.gd`; comparisons in `tools/compare/`.
- **OpenXR without a headset:** `tools/test_openxr.sh` (~3 min; `tests/openxr_smoke.gd`: the rate, the menu's rows, the speed check): `monado-service` with `XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1`, whose stdin must be a pipe or FIFO (it epolls stdin and quits at once on `/dev/null`). Its null compositor offers one rate, 20 Hz, 128×128 per eye, and paces a slow app at every 2nd refresh with a doubled `predictedDisplayPeriod`. Reading eye images back fails there; for images use `fake_hmd.gd` or "Native mobile". While `monado-service` runs, any Godot started here connects to it as a headset: don't run `test_stereo.sh` or `tools/test.sh` at the same time. Monado's simulated controllers (`SIMULATED_LEFT=wmr`) bind to none of our profiles, and Monado has no Frame profile (Godot leaves it out there, silently): controller input in tests comes from `XRControllerTracker`s with inputs set by hand (`U.controller`).
- **Foveation in the Frame's driver:** `tools/fdm_check.sh` (~10 s): Godot on Turnip over the noop drm-shim, the XR view through `fake_hmd.gd` at 1728² per eye, and the driver's trace (`MESA_GPU_TRACES=print`, `TU_DEBUG=perf`) per render pass: in tiles or not, attachments, tiles. Off: no tiles; split: tiles; on and own: tiles and one attachment more (the density map). With `TU_DEBUG=gmem`, tiles wherever they are possible: without a GPU Turnip's autotune picks by the samples the drm-shim makes up.
- **A build for the one-eye check:** `tools/export.sh --check`: an empty file `godot/check` while it exports turns the stereo check scene on (`main.CHECK_FLAG`, in the export's include filter, not in git).
- **Export:** `tools/export.sh [--check] [label]` (~40 s): Godot's export of the preset "Steam Frame (Linux arm64)", the only one, into `godot/build/wormhole_vr.arm64` (in the container on the Frame), then on the Frame into `~/wormhole-vr` (the file replaced at once: a running build keeps the old one), elsewhere into `godot/build/wormhole_vr_<label>_steam_frame.zip` (label: the branch by default).
- **Tracer accuracy:** `python3 ref/test_gpu.py` (~4 min; EGL), `ref/test_fast.py`, `ref/test_eye.py` (~4 min, plain-Python RK4), `ref/test_slice.py` (the arrows' surface against RK4 rays, ~2 min), `ref/test_gravity.py`. `test_gpu.py` prints errors, no verdict: compare them with the same run on the code before a change (`WH_BALLS=0` too: the shader without balls). `ref/wh.py` `fast` mirrors the shader's curved-region method in float64; keep the two in step.
- **What the headset's compiler makes of the shader:** `tools/adreno_stats.sh [scene] [--shader res://...]` (3 s; scenes of `tests/perf.gd`: plain, near, away without movable objects, check or balls with them): Godot on Mesa's Turnip (Adreno 750) over the noop drm-shim, which `setup.sh` builds into `tools/.bin/mesa-fd`; it prints instructions, nops, registers and waves of the ray tracer (Godot compiles it twice: a generic ubershader, then the specialised one; a shader with more than 100 vec4 of constants also gets an unused "safe constlen" variant N/2). Registers per pixel set the waves at once (48 → 4, 24 → 8, 16 → 12, 13 → 14; at 12 or fewer the compiler runs waves of 128). No timings: there is no GPU. `KEEP_LOG=file` keeps the whole log; two logs' programs compare with `adreno_cost.ray_program` (a change that should not touch the shader's code, such as comments or a dead `#ifdef`, must give the same program byte for byte). `--disasm` dumps the biggest program, the ubershader, not the one that runs.
- **Where the registers go:** `python3 tools/ir3_live.py LOG` (LOG from `KEEP_LOG=... tools/adreno_stats.sh`): live register components at every instruction (backward liveness over its branches), the peak and the code around it; the uniform loads there (`c<a0.x + N>`) tell which uniforms. Half registers count, two to a full component; shared ones (r48-r55) do not. 47 components is the plain shader's 12 registers, 97 the balls shader's 24.
- **Cost without a headset:** `tools/adreno_cost.sh [--check] [--toys [--hands|--held]] [--gravity 1|2] [--split] [--poses "l,yaw,pitch;..."] [--profile] [source]...` (sources as `ab_shaders.sh`, `this` = the tree; ~1 min each). Mesa's compiler for the Frame compiles the ray tracer, `tools/ir3_emu.py` runs the specialised program on waves at the speed check's poses (one eye, 1728², 104°) and counts issue cycles, divergent branches included (lowest PC first, as `ir3_reconvergence.c` describes). `--check` compares the emulated colours with Godot's lavapipe picture: run it after every change to the shader or the emulator. Fitted on the headset's speed check (four ray tracers, nine poses of world A): per 64 pixels, ms ≈ 0.8 + 1.61e-3 × ALU issue cycles + 1.05e-3 × nop slots + 0.0258 × transcendentals (cat4) + 0.146 × texture-unit instructions (cat5: derivatives, samples); rms 0.19 ms. A transcendental costs ~16 ALU cycles, a screen derivative ~90. It does not know memory waits. Out of its fit: fewer transcendentals promised -7% and gave -0.7% in the headset; in world B outside the edge it says 3.8 ms where the headset takes 4.8; the balls shaders it misses by ~1.8x and their ratios are too modest (0.78 promised, 0.57-0.64 measured): trust it for the plain shader, not for absolute numbers of the toys'. `--split` models the stencil split with the proxies `tests/emu_dump.gd` dumps; `--hands` / `--held` give each pose its own uniforms. The UBO layout is `adreno_cost.UNIFORMS`: keep it in the view include's order.
- **Measuring in the headset without the owner walking:** the menu's last row, A (or, in a build made with `tools/ab_shaders.sh --auto ...`, the start) runs `godot/bench.gd` (`docs/steam-frame.md`, «Замер скорости»). A frame's cost depends only on the pose (l, yaw from the throat, pitch, roll): (1) at 72 Hz, thirteen fixed poses, each timing every ray tracer in the build (`godot/shaders/ab/`, not in git, from `tools/ab_shaders.sh`: earlier commits, directories, or cost checks empty/flat/noshade/noderiv/nogrid/nosky made from the tree) in a palindrome order, `bench:` lines; this build's six ways (foveations) and with the demo's toys a seventh, over the whole view ("трафарет -N%"); other sources' toys shader over the whole view (the stencil all marked if theirs reads it); (2) at 120 Hz, this build's ray tracer on a tour, a `tf` line per frame and a `tour:` line per second. Frame times from walking around do not compare between builds: where one looks changes them several times. `frame_rate.gd` also logs a `refresh:` line every second and one per late frame.
- **Pictures against another commit:** render both at many poses with `tests/emu_dump.gd` (`... -- out.json "l,yaw,pitch;..." fov plain|balls|toys[+gravity1|2][+hands|+held] [shader]`) and diff the PNGs.
- **GitHub:** on the Frame git pushes with the owner's account through `gh` (`~/.local/bin/gh`, `gh auth setup-git`); commits go as `Claude <noreply@anthropic.com>` (the repository's own git config). In a cloud session branch pushes work through the session's git proxy, tag pushes are refused (403). Either way the owner creates tags on GitHub.

## Things learned the hard way

The Steam Frame, SteamVR and Godot:
- **Godot multiview.** `INV_VIEW_MATRIX` is a shared camera between the eyes; each eye's offset and rotation live in its `PROJECTION_MATRIX`; `EYE_OFFSET` is the eye in that view space. Rays must start at the eye (`docs/rendering.md`, «Луч каждого глаза»): from the head centre the eyes looked in different directions.
- **The stereo check's chart → play map** is computed at placement and recentre (and after stick moves and turns), never every frame from the feet: then it is fixed to the room, and world drift shows as green parting from white.
- **SteamVR on the Frame** shows a non-Steam app's desktop window on a virtual screen inside the headset: XR renders into a SubViewport and the window only shows a notice. While the SteamVR dashboard is open the app gets no input.
- **Refresh rate.** The Frame starts this app at 72 Hz; its display does 72/80/90/96/108/120/144. SteamVR there answers `XR_FB_display_refresh_rate` requests with success and ignores them; it follows the app's setting `steam.app.<SteamAppId>.preferredRefreshRate`, set with `/opt/steamvr/bin/linuxarm64/vrcmd`, and on our Frame (SteamVR 2.18.2) the running app switches within a second (`frame_rate.gd`). It does not offer `XR_EXT_performance_settings`. The GPU stays at its top clock (903 MHz) while frames are too slow.
- **144 Hz and SteamVR's half rate.** One late frame sends SteamVR to every 2nd refresh for 6-14 s; it then fills in frames on the same GPU, and our frame at the same pose reads 50-100% dearer (at 120 → 60 Hz, 7-8 ms even at the start, where it costs 2.6), so it stays trapped until the frame gets cheaper (looking away from the throat) or the rate is switched there and back. The Steam overlay and SteamVR's camera view (~3 ms of GPU a frame) cause the same. The app can't stop it; cheaper frames make it rarer.
- **Foveated rendering (Godot 4.7.2 on the Frame).** Turnip applies a density map per tile, only when it renders in tiles, and renders a pass without tiles if a subpass dependency lacks `VK_DEPENDENCY_BY_REGION_BIT`: Godot 4.7.2's two-subpass pass at 100% has one (godotengine/godot#124141, fixed after 4.7.2), so `split_pass.gd` (an empty POST_TRANSPARENT CompositorEffect) splits it. Subsampled images: off (SteamVR can't read them). Godot asks for the eye-tracked offsets only with `xr/openxr/extensions/eye_gaze_interaction` on, and in full-size pixels. The swapchain gets a density map only if `foveation_level` > 0 at creation (`project.godot` asks for 3; "off" is `vrs_mode` disabled). No shading-rate VRS on the Frame: the sharp zone is a rectangle of whole tiles. Our own map is a `Texture2DArray` set with `RenderingServer.viewport_set_vrs_texture` and `VRS_UPDATE_ALWAYS` (a buffer rebuild leaves the driver's map empty otherwise). Godot maps a colour c to density 1 - c, Turnip a density d to 1/d floored to a power of two: 4x is byte 192 (191 gives 2). `verbose_stdout` (off: hundreds of lines) lists the extensions and the driver's support.
- **A pixel's ray from the corners, never from its screen position:** exact under any density map (a coarse pixel gets the ray through its centre). With foveation first on, when rays came from `SCREEN_UV`, the owner saw space "breathe" around the head; the cause was never proven (the map did nothing then), and with today's rays and maps it has not come back.
- **Controllers.** Godot 4.7.2 knows the Frame's own profile (`/interaction_profiles/valve/frame_controller_valve`, `XR_VALVE_frame_controller_interaction`, asked for by itself). Before the map had it, the log's `interaction profile` lines showed both controllers as `khr/generic_controller`. Valve's page «Steam Frame Input» lists the Frame's paths: left `dpad_up/down/left/right`, `view`, `system`, `bumper`; right `a`, `b`, `x`, `y`, `menu`, `system`, `bumper`; both `squeeze` (value, click, touch), `trigger`, `thumbstick`, `grip/pose`, `aim/pose`, `output/haptic`; SteamVR takes the Frame profile when the app offers it, else the generic one, else Touch, remapped (Touch's menu is View, its upper button all three upper buttons). One path a runtime rejects drops that whole profile: Monado rejected `grip_surface/pose` on Touch, and no Touch input worked at all. Whether SteamVR takes our Frame profile has not been seen in the headset yet (the log says).
- **The OpenXR interface's signals:** a GDScript lambda connected to one corrupted the heap at exit (under Monado); a method callable does not. `tools/test_openxr.sh` fails on a crash at exit.
- **Godot on the Frame's host** (why the tools leave it): it connects to SteamVR unless `XR_RUNTIME_JSON` points elsewhere; gamescope's Vulkan layer makes its swapchains on the owner's screen even under xvfb-run; without the layer Turnip finds no queue that presents to Xvfb; there is no lavapipe.
- **Logs:** `~/.local/share/godot/app_userdata/Wormhole VR/logs/` on the Frame; from the PC `tools/frame_logs.bat`. Screenshots (`tools/frame_screens.bat [days]`) are 1920×1080 JPEGs of one eye's view, in `userdata/<id>/760/remote/<the 64-bit game id>/screenshots`. `application/run/flush_stdout_on_print` is on: without it an export buffers `print()` and an abort on quit loses the log.
- **Kernel files.** A sysfs file says it holds 4096 bytes, and `FileAccess.get_file_as_string` reads that many: garbage after the value. Read them with `get_line()` (`FrameRate.read_line`).
- **GDScript's `Vector2/3/4` are single precision** (`float` is double): an ODE or a table kept in them made the gravity's second derivative noisy at 10⁻³; keep such states in plain floats or `PackedFloat64Array`.
- **A method named like a native one** (`set_scale` on a Node3D) is a parse error: the project treats warnings as errors.
- **The stencil in Godot 4.7.2** (`stencil_mode read|write, compare_..., ref` in a spatial shader) works on Mobile, multiview and lavapipe. Opaque draws follow `render_priority`, lower first. A MeshInstance3D whose ShaderMaterial has no shader yet is drawn with Godot's default lit material (an 8700-instruction program): make such a node only once its shader is known.
- **Godot prints shader float constants with 14 decimals:** `1e-30` and `1e-20` become 0.0; `1e-12` survives. GPUs' `max`/`min` return the other operand for a NaN, which hides most of it.
- **Godot shading language** reserves `E`, `PI`, `TAU`: a local `E` is a compile error that GLSL (`ref/`) accepts.

The Adreno 750 and its compiler (ir3):
- **Measure in the headset, not by counting instructions.** A flat trace with fewer instructions was 7-15% slower on the Frame; 13 registers instead of 16 made no difference; waves of 128 (12 registers) against 64 (13) gained nothing. Compare variants with the speed check at 72 Hz: a variant over the frame's budget halves the rate, reads dearer than it is, and so does the segment after it.
- **Registers are taken by code no pixel runs.** The GPU reserves a shader's registers for its heaviest point: code for something not in view still costs (the toys' code held the plain scene at 48 registers once; the arrows took the floor view from 12 to 16). Hence one shader per combination (`WH_NO_BALLS`, `WH_GRAVITY`, `WH_ARROWS`), loops over objects to `wh_nBall` (a constant bound with `break` is unrolled), candidates as bit masks.
- **ir3 turns an `if` into selects** even around a square root: every lane pays. A loop of one pass with a bound it cannot see (`k < 1 + min(wh_nBall, 0)`) stays a branch that waves skip; the same trick keeps a loop from being unrolled (`k < 4 + min(wh_nCube, 0)`).
- **ir3 does not hoist loop-invariant code, but merges equal expressions:** a value computed before a loop is held through it; computed again where used (from values held anyway) it is not. That took the balls shader from 32 to 24 registers.
- **Branches that skip work lose** when their divergence costs more than the work (bounding balls before each box, in the model and in the headset).
- **Derivatives** are only defined in uniform control flow: `wh_renderE` computes the lines' coordinates for every pixel and their derivatives once, after the trace. A screen derivative costs ~90 ALU cycles.
- **16-bit math** (`mediump`) runs at double rate in waves of 128, but the conversions cost more than they saved for the sky's colours; line coordinates need float32.
- **Uniform arrays at a computed index** compile to `mova a0.x` + `c<a0.x + N>` (a0.x counts components). a7xx's `shlm`/`shrm`/`shlg`/`shrg` take the shift amount first (Mesa `isa/ir3-cat3.xml`).
- **ir3's prog N/2 is unused:** a shader with more than 100 vec4 of constants is compiled again reading them from memory; Turnip runs that only if the stages need more than 512 vec4 (ours ~200).
- **Software-Vulkan timings** are only good for ratios, and not for the shader's inner costs.
- **Where a frame at the shell's edge goes** (model): curved-region setup ~44%, the flat trace after the shell ~25%, shading ~22% plus derivatives; a third of the issued cycles are nops of dependent chains. In the headset shading was ~40% (1.9 of 4.7 ms) when the edge cost 4.7: near the throat one group of pixels holds both skies, the floor and objects and runs every branch. Godot's own cost (a one-colour shader) is 0.8 ms.

The ray tracer's numerics:
- **The fillet table:** e(b) has a 1/sqrt(mx) factor that goes to zero like a square root at b → Rout; interpolating e itself erred 0.3°, e·sqrt(mx) (put back per pixel) 1e-5 rad. One row per regime: the regime comes from the row, so the moments match the table. Sample with `textureLod` (no implicit derivatives).
- **Rays that go round the throat** (|vl| below ~2e-4 on the cylinder, looking sideways inside it) lose float32 digits: 1 - wc² as a difference of near-equal numbers (now (rho0 - b)(rho0 + b) with rho0 - b from vl²), and a hit key 2 + a fraction of ~1e-5 (piece B now goes without an offset). No pixel has vl exactly 0, so it shows as dashes; the reference's and the emulator's cameras never had a pixel that close: a pose at an odd width (the middle column at vl = 0) finds such things.
- **A turning ray's turning point was 0 / 0** in `wh_filMom` (`t / (z + zlo)` at t = z = zlo = 0), where the toys' search samples: NaN poisoned the rest of the ray. Now `z - zlo` (in `ref/wh.py` too). Scan viewpoints around an object when a test's poses may miss a corner case.
- **`inversesqrt` rounding** gave |w| above 1 for rays along the cylinder (b = rho0): `min(dot(w, e2), 1.0)`. An image diff against the code before caught it.
- **The fog's path length** only needs ~5%: r²/b × psi with r at the weight's mean tau; the toys' hits are ordered by place on the path (piece + fraction), not by length: one polynomial and registers fewer.
- **Moving objects in the curved region: chords, not samples.** Between two samples the chord in R^4 is tested against each object, and the path's point at the chord's entry is the hit if it lies within the chord's sag (sampling alone lost a cube's edge on the floor; an unchecked chord of a ray winding round the throat cut across a cube). They cost per ray, not per object in view: an object is searched only where the path is within reach in r and w, and on a fillet within its psi window (`wh_filSolve`); a ball at the eye or in the throat is a candidate for many rays.
- **Balls far from the throat** must not be candidates in the curved region, or every ray through the throat samples them.
- **Render scale and the stereo test:** below 100% the bilinear upscale shifts the one-colour threshold of `tools/compare` by 0.2-0.4 px; with `SCALING_3D_MODE_NEAREST` the suite passes at 80% within 0.02 px: test a scale that way.
- **The one-eye check in the headset** is what catches problems only the real device has. Run it after any change to rendering.
