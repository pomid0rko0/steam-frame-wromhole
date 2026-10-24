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
- `walking` — the left stick walks (left trigger runs), the right stick snap-turns 30°, A goes
  back to the start (`tests/walking_test.gd`).
- `throat` — throat knobs: the right stick up/down changes the throat length, with the right
  grip held the fillet; A resets (`tests/throat_test.gd`).
- `physics` — balls and cubes with physics in the curved space (`ball_world.gd`,
  `tests/physics_test.gd`, `tests/multiview_cubes.gd`): a cube and a ball are thrown after the
  start, right A throws again.
- `grab` (`walking` + `physics`) — grip grabs and throws balls, B makes a new one, hands and
  the avatar as balls (`tests/grab_test.gd`).
- `foveation` — foveated rendering on, as it was when space "breathed" in the headset; the
  cause is not found.
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
- the right stick: x turns in `walking`, y changes the throat in `throat`; that fits.
- A resets in `walking`, `throat`, `grab` and `physics` (toys back in place, thrown again): one
  reset does all of it.
- a throat change with balls (`throat` + `physics`): balls must keep their distance to the
  edge of the curved shell, as the feet do in `set_geometry`.

## Hard rule: stereo before headset

Broken stereo physically hurts in a headset. Before handing over any headset build, run
`tools/test_stereo.sh` on exactly that source; it must pass (exit 0). If you add things Godot
draws next to ray-traced ones, check they line up the same way.

## Running things

- **Fresh machine:** `tools/setup.sh` downloads Godot 4.7.2 into `tools/.bin` (and links it as `godot` in `/usr/local/bin`), the export templates and the pip packages, and installs xvfb and lavapipe with apt if they are missing.
- **Fresh clone:** run `godot --headless --path godot --import` once before running test scripts with `-s`, or `class_name` types such as WormholeSpace are unknown. `test_stereo.sh` does it itself.
- **Stereo:** `tools/test_stereo.sh` (~15 min).
- **Tracer accuracy:** `python3 ref/test_gpu.py` (~4 min), `ref/test_fast.py`, `ref/test_eye.py`.
- **Branch tests:** each branch's own, `--fixed-fps 60 -s res://tests/<name>_test.gd` (`walking`, `throat`, `physics`, `grab`).
- **Export:** from `godot/`: `--export-release "Steam Frame (Linux arm64)" build/wormhole_vr.arm64`.
- **OpenXR without a headset:** `monado-service` with `XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1`, started ~8 s before Godot. Reading eye images back fails there; for images use `fake_hmd.gd` or Godot's "Native mobile" interface.
- **GitHub from this environment:** branch pushes work through the session's git proxy, tag pushes are refused (403). The owner creates tags on GitHub.

## Things learned the hard way

- **Godot multiview.** `INV_VIEW_MATRIX` is a shared camera between the eyes; each eye's offset and rotation live in its `PROJECTION_MATRIX`; `EYE_OFFSET` is the eye in that view space. Rays must start at the eye (README, «Стерео»). Starting them at the head centre made the eyes look in different directions.
- **The overlay's chart → play map** is computed at placement and recentre (and in `walking` after stick moves and turns), never every frame from the feet. Then it is fixed to the room, and world drift shows as green parting from white.
- **Foveated rendering** (VRS, `xr/openxr/foveation_*`) made space "breathe" around the head and caused nausea on the Frame. It is off; don't turn it on without a headset check.
- **SteamVR on the Frame** shows a non-Steam app's desktop window on a virtual screen inside the headset. So XR renders into a SubViewport and the window only shows a notice.
- **Refresh rate.** The Frame starts this app at 72 Hz; it offers 72/80/90/120/144 (144 experimental). The stereo-check scene measured 9.4 ms GPU per frame at 72 Hz. `refresh-rate` has the on-headset panel and `tests/perf.gd`.
- **SceneTree test scripts.** In them `main._ready` has not run during `_initialize`; touch main's nodes from `_process` (frame 2 or later). Settings applied too early silently do nothing.
- **Software-Vulkan timings** are only good for ratios.
- **Balls in the shader.** A ball far from the throat must not be a candidate in the curved-region integrator (`wormhole_core`). The integrator steps by `reach`, the R^4 distance to the nearest candidate (the path is never shorter than the chord), so a candidate costs fine steps only near it; before that, one ball in the throat made every ray through it sample the whole way finely. The same holds for cubes. Loops over uniform arrays in the flat trace need a non-constant bound (`wh_nCube`): an unrolled empty loop cost 6-15% of the frame.
- **Godot's shading language** has built-in constants (`PI`, `TAU`, `E`): a variable named `E` fails to compile.
- **`fwidth` next to a silhouette** in the curved region takes the neighbouring pixel's value, which belongs to another object; the throat circle on the floor showed a cyan fringe around objects until its width was capped.
- **Physics in GDScript** costs about 0.2 ms per frame for a sliding cube (contact solver); resting cubes sleep. Watch it before adding many bodies.
- **The one-eye check in the headset** is what catches problems only the real device has. Run it after any change to rendering.
