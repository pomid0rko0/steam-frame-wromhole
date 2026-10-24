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

- `main` — the wormhole, static objects, walking in the room, the stereo check scene (off).
- `refresh-rate` — the frame rate panel; a trigger steps the headset's refresh rate.
- `walking` — the left stick walks (left trigger runs), the right stick turns smoothly or in 30°
  snaps (a right stick click switches), A goes back to the start (`tests/walking_test.gd`,
  `tests/walking_xr_test.gd`). Also renderer work `main` lacks: the Gauss quadrature in
  `wormhole_core` and dynamic resolution (`render_scale.gd`), for the frame cost at the shell's
  edge, which the stick makes reachable.
- `throat` — throat knobs: the right stick up/down changes the throat length, with the right
  grip held the fillet; A resets (`tests/throat_test.gd`).
- `physics` — balls with physics in the curved space (`ball_world.gd`, `tests/physics_test.gd`).
- `grab` (`walking` + `physics`) — grip grabs and throws balls, B makes a new one, hands and
  the avatar as balls (`tests/grab_test.gd`).
- `foveation` — foveated rendering on, as it was when space "breathed" in the headset; the
  cause is not found.
- `controls` — the old sketch that `walking`, `throat` and `grab` were split from (on
  `physics` on `refresh-rate`); don't start from it.

Where the README wishes start (wishes without a branch start from `main`):
- stick locomotion on the floor → `walking` (smooth stick walking, smooth and snap turn are there);
- free flight in 3D with gravity on/off → `walking` (the gravity field is in `physics`);
- pick up and throw, pulling objects like in Half-Life: Alyx → `grab` (grip grab and throw
  are there);
- cubes next to balls → `physics`;
- throat shape, VR-friendly knobs, test scenes → `throat` (throat length and fillet on the right
  stick);
- refresh rate → `refresh-rate`;
- foveated rendering → `foveation`;
- placing wormholes by hand, several wormholes, flat portals, two-handed shooting, gun models,
  other shapes (torus, arbitrary SDF) → `main`; several wormholes, portals and other shapes are
  renderer work (`wormhole_core` and a reference in `ref/` first);
- the avatar: its head ball around the eyes makes every ray inside the throat sample it finely
  and the frame drops; it is off by default in `grab`.

When branches are put together, these overlap:
- the left trigger: `refresh-rate` steps the rate with either trigger, `walking` runs with the
  left one. Together the rate goes to left X (the panel's hint says which button).
- the right stick: x turns in `walking` (its click switches smooth/snap), y changes the throat in
  `throat`; that fits.
- A resets in `walking`, `throat` and `grab`: one reset does all of it.
- a throat change with balls (`throat` + `physics`): balls must keep their distance to the
  edge of the curved shell, as the feet do in `set_geometry`.

## Hard rule: stereo before headset

Broken stereo physically hurts in a headset. Before handing over any headset build, run
`tools/test_stereo.sh` on exactly that source; it must pass (exit 0). If you add things Godot
draws next to ray-traced ones, check they line up the same way.

## Running things

- **Fresh machine:** `tools/setup.sh` downloads Godot 4.7.2 into `tools/.bin` (and links it as `godot` in `/usr/local/bin`), the export templates and the pip packages, and installs xvfb, lavapipe, EGL/GLES and Monado with apt if they are missing. A tool you had to install by hand goes into it too.
- **Fresh clone:** run `godot --headless --path godot --import` once before running test scripts with `-s`, or `class_name` types such as WormholeSpace are unknown. `test_stereo.sh` does it itself.
- **Stereo:** `tools/test_stereo.sh` (~15 min).
- **Tracer accuracy:** `python3 ref/test_gpu.py` (~4 min), `ref/test_fast.py`, `ref/test_eye.py`.
- **Branch tests:** each branch's own, `--fixed-fps 60 -s res://tests/<name>_test.gd` (`walking`, `walking_xr`, `render_scale` with `--headless`, `render_scale_xr`, `throat`, `physics`, `grab`). Run them under `timeout`: a test script that fails to compile leaves Godot running forever.
- **Frame cost along the walk:** `tests/path_cost.gd` (GPU ms per place from the start through the throat).
- **Export:** from `godot/`: `--export-release "Steam Frame (Linux arm64)" build/wormhole_vr.arm64`.
- **OpenXR without a headset:** `monado-service` with `XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1`, started ~8 s before Godot, with stdin from a pipe (`sleep 300 | monado-service &`: with stdin at /dev/null or a file it exits on `epoll_ctl(stdin) failed`). `SIMULATED_LEFT=wmr SIMULATED_RIGHT=wmr` adds controllers, but WMR ones bind to none of our profiles, so the log only shows whether the action map is accepted. Godot aborts on quit there (status 134): read the log, not the exit status. Reading eye images back fails there; for images use `fake_hmd.gd` or Godot's "Native mobile" interface; for controller input, `XRControllerTracker`s with inputs set by hand (`tests/walking_xr_test.gd`).
- **GitHub from this environment:** branch pushes work through the session's git proxy, tag pushes are refused (403). The owner creates tags on GitHub.

## Things learned the hard way

- **Godot multiview.** `INV_VIEW_MATRIX` is a shared camera between the eyes; each eye's offset and rotation live in its `PROJECTION_MATRIX`; `EYE_OFFSET` is the eye in that view space. Rays must start at the eye (README, «Стерео»). Starting them at the head centre made the eyes look in different directions.
- **The overlay's chart → play map** is computed at placement and recentre (and in `walking` after stick moves and turns), never every frame from the feet. Then it is fixed to the room, and world drift shows as green parting from white.
- **Foveated rendering** (VRS, `xr/openxr/foveation_*`) made space "breathe" around the head and caused nausea on the Frame. It is off; don't turn it on without a headset check.
- **SteamVR on the Frame** shows a non-Steam app's desktop window on a virtual screen inside the headset. So XR renders into a SubViewport and the window only shows a notice.
- **Refresh rate.** The Frame starts this app at 72 Hz; it offers 72/80/90/120/144 (144 experimental). The stereo-check scene measured 9.4 ms GPU per frame at 72 Hz. `refresh-rate` has the on-headset panel and `tests/perf.gd`.
- **SceneTree test scripts.** In them `main._ready` has not run during `_initialize`; touch main's nodes from `_process` (frame 2 or later). Settings applied too early silently do nothing.
- **Software-Vulkan timings** are only good for ratios, and only between runs made back to back with nothing else running: a numpy job alongside made one run 40% slower than the next.
- **The frame cost peaks at the shell's edge** (|x| = Rout around the centre): almost every ray integrates the curved region there, about twice the start's cost in `path_cost.gd`, less again deeper in the throat. In the headset, crossing it with the stick glitched the picture; the picture there is exact (checked against the float64 reference on both sides), so most likely it was the frame time (not yet confirmed in the headset). The answer is the Gauss quadrature (~17% off there) and dynamic resolution (`render_scale.gd`, OpenXR only; its steps go to `godot.log`).
- **Balls in the shader.** A ball far from the throat must not be a candidate in the curved-region integrator (`wormhole_core`), or every ray through the throat samples it finely. A ball around the eye (the avatar's head) still does that inside the throat.
- **The one-eye check in the headset** is what catches problems only the real device has. Run it after any change to rendering.
- **Controllers.** Without its own profile in the action map, the Steam Frame shows its controllers to apps as Oculus Touch (Godot 4.7.2 knows the Frame's own, `/interaction_profiles/valve/frame_controller_valve`; it is not in our map). One path a runtime rejects drops that whole profile's bindings: Monado rejected `grip_surface/pose` (the palm pose) on Touch, and then no Touch input worked at all. The palm pose is unused here and out of the map.
- **Logs from a release build.** Without `application/run/flush_stdout_on_print` (on in `project.godot`) an export buffers `print()`, and an abort on quit loses every printed line from `godot.log`, the headset's too.
- **Tests with `fake_hmd.gd` abort at exit** (status 134) unless the interface and trackers are taken down first; `walking_xr_test.gd` does it, so its exit status means something.
