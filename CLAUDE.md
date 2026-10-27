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
- **Long runs first, in the background; the build at once.** The owner checks builds in the headset while the tests run and does not want to wait for them, not even for `test_stereo.sh`. As soon as the code for a build is in place: start `tools/test_stereo.sh` in the background first, export the build and attach it at once, saying the tests still run. Every other check that takes minutes (`tools/test_openxr.sh` ~3 min, not together with `test_stereo.sh`: Monado; `gravity_test`, `physics_test`, `grab_test`, `bench_test`, ~1-2 min each; `ref/test_gpu.py` ~4 min) runs in the background too, after or beside it, and what it finds is reported and fixed afterwards. Never sit in the foreground on a run of minutes while the owner waits.

## Branches

Each wish has its own branch from `main`, so each can be checked in the headset alone. Only
`grab` holds more: `walking` and `physics` merged (grabbing works on `physics` balls, and the
stick takes you to them). `main` has been checked in the headset (rendering and stereo, with the
one-eye check; its tag marks the commit), the others have not; each README describes its code.

- `main` — the wormhole, static objects, walking in the room, the stereo check scene (off), the
  menu (from `menu`, merged, below): hidden until Menu / View or a left stick click opens it,
  worked with the D-pad (or the left stick), A and B, it sets the refresh rate, the render scale,
  foveation and the rest; closed, a line low in the view shows the measured rate and whether
  frames keep up. Stick locomotion (from `walking`): the left stick walks (left trigger runs),
  the right stick turns smoothly or in 30° snaps (a right stick click switches), A
  goes back to the start (`tests/walking_test.gd`, `tests/walking_xr_test.gd`). Checked in the
  headset: all of it works, a little nausea, bearable; crossing the shell's outer edge by stick is
  clean (before `fast-rays` the picture glitched there: frames dropped at 16.6 ms). The cheaper
  edge frames of `edge-120hz` (merged, below) and the cost model are in it too. Foveated
  rendering (from `foveation`, merged, below) is on by default: our narrow map, the width first.
  Gravity through the wormhole, its views and the balls-and-cubes demo (from `gravity`, merged,
  below) are in it: the demo is always on, so the normal scene runs `wormhole_balls`. The cheaper
  demo (from `toys`, merged, below) is in it too: the toys sorted by region and searched in
  windows, the frame split by the stencil, and the throat's "stripe" fixed. Grab and throw (from
  `throw`, merged, below) are in it too: the hands as balls, grip takes a ball or a cube and lets
  it fly, right B a new ball, the D-pad down (left X without the Frame's profile) a new cube.
- `walking` — merged into `main`; stick locomotion wishes start from `main` now.
- `throat` — throat knobs: the right stick up/down changes the throat length, with the right
  grip held the fillet; A resets (`tests/throat_test.gd`).
- `physics` — balls with physics in the curved space (`ball_world.gd`, `tests/physics_test.gd`).
- `grab` (`walking` + `physics`) — grip grabs and throws balls, B makes a new one, hands and
  the avatar as balls (`tests/grab_test.gd`). The old core; `throw` (merged into `main`) redid it there.
- `throw` — merged into `main` (the owner tried it in the headset twice and asked to merge): grab
  and throw (README «Руки: взять и бросить»): each hand a 4 cm
  ray-traced ball at the grip pose (`main.grips`), placed by a geodesic from the head with the
  room's axes carried along (`main._update_hands`); it pushes the toys and turns green within
  12 cm of one; grip takes the nearest ball or cube, kept at its offset and turn in the hand's
  axes (`WormholeSpace.toward`, the inverse of `geodesic`); let go, it flies with the velocity and
  spin of its last 60 ms in the hand (`main._velocity`: the derivative of the parabola through
  three places, no lag on an arc); held toys are kinematic in `BallWorld` (`held`); right B a new
  ball, left X a new cube in the hand; haptics; nothing during `main.hold`; A empties the hands.
  `tests/grab_test.gd` drives it through `fake_hmd.gd` and controller trackers (grip poses set,
  tracking lost with `invalidate_pose`, as Godot's OpenXR does) and looks at the left eye.
  Tried in the headset: grabbing, throwing, bouncing, rolling work. Found there and fixed: a crack
  through a toy at the shell's edge (`wh_filMom`'s 0 / 0, below), the frame at 25 ms with a toy
  held at the shell's edge (the fillet's psi window, below), the hand and held toys pushing at
  1.85x their speed and flinging what they press (`BallWorld.RESTITUTION_KINEMATIC` 0.3), throws
  at 15-20 m/s from a flick of the wrist (a toy leaves with the hand's velocity, not its own: held
  half a metre off, the wrist's turn times that lever). Then the owner wanted to watch a ball set
  down at the shell's edge roll into the throat by itself: gravity pulls along the floor there
  only 0.01 g (0.06-0.1 g where the fillet meets the cylinder), and 0.04 g of rolling friction held
  it still. Now rolling friction is 0.005 g + 0.1/s times the speed, with air drag (as v², in
  flight too, `BallWorld.TOY_DENSITY` 25 kg/m³; `air` off in physics_test's checks of the motion
  itself), a hand slower than 0.15 m/s sets its toy down at rest (`main.SET_DOWN_SPEED`), the hand
  that let go does not push it until 1 cm apart (`ghost`), and the demo's ball is thrown 1.8x
  harder to climb out of the throat's well into B. The second try in the headset: balls throw
  "really well", toys feel heavy (good); cubes spun at 37-39 rad/s from a flick of the wrist and
  hopped about (no energy gained, checked). The cause: a held toy is kinematic, so the hand is
  infinitely strong. A share of the hand's turn at the release was tried and called a crutch by the
  owner; the honest fix, a hand of finite strength (README wish «Рука конечной силы»: the held toy a
  body pulled to its place by a limited force and torque), is for another chat. A ball set down half a metre outside the shell's edge rolled
  in: right (the field at its centre, 20-35 cm up, leans 0.3-0.5° toward the throat; the arrows
  and the floor's colours can't show that; README «Почему мяч скатывается и снаружи кривой зоны»).
  Its log: 72 Hz always holds; at 120 Hz frames in the shell cost 4.4-5 ms, but a ball held at the
  edge gives single frames up to 8 ms and the arrows 1.5-2 ms more, and one late frame traps
  SteamVR at 60 Hz until one leaves the shell. Not solved: that, the cubes' spin, the hands' ~8%
  (model), 144 Hz.
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
- `gravity` — merged into `main`: gravity through the wormhole from Laplace's equation, as in optozorax's video about
  gravity and portals (README «Гравитация через червоточину», «Мячи и кубы»): the math from
  `physics` (e493a20: `ref/gravity.py`, `ref/test_gravity.py`, `WormholeSpace.gravity_f`,
  `potential`, `potential_grad`, `floor_gravity`, all in doubles), `physics`'s balls and cubes
  (`ball_world.gd`, `tests/physics_test.gd`) and its demo (the toys at rest, a cube and a ball
  thrown, two balls dropped together beside the wormhole and in the throat; A resets it all), drawn
  by `main`'s fast core: cubes are new there, found in the curved region by chords between samples
  (README «Мячи и кубы»); a view of gravity: the floor coloured by its strength, arrows of the field
  on the surface x = 0 through the wormhole (`main.set_gravity_view`; the panel's row, left Y, G; on `main` now the menu's row and the D-pad up).
  Shaders: `wormhole.gdshader` (nothing movable: as on `main`), `wormhole_balls` (the toys),
  `wormhole_gravity`/`wormhole_arrows` and `wormhole_balls_gravity`/`wormhole_balls_arrows`;
  `tests/gravity_test.gd`, `tests/multiview_cubes.gd`, `ref/test_slice.py`, cubes in `ref/test_gpu.py`;
  the stereo check scene has a magenta cube with Godot's green edges (`check_cube.gdshader`). The
  demo is always on, so the normal scene runs `wormhole_balls` (32 registers, 6 waves): by the model
  5.8 ms over the speed check's poses (plain 3.5; `main`'s ball shader with the same balls 16.4),
  with the gravity views 5.9 / 6.6 (`tools/adreno_cost.sh --toys [--gravity 1|2]`). Checked in the
  headset: the throw, the roll into B, the slow fall in the throat, A. Found there (README wishes
  «Кубы и шары», «Дешевле демонстрация с мячами и кубами», «Свет в горле смешивается»): 144 Hz no
  longer holds (start 4.0 ms against 2.4 for the check build, 120 Hz, our narrow map); inside the
  throat looking sideways 7.6-11 ms (the throat's ball and cube are every inner ray's candidates;
  next: a window in psi on the cylinder); a "stripe" through the throat's ball and cube (found
  from the owner's screenshots and fixed on `toys`, merged: rays that go round the throat, below); the
  ball in the middle of the throat lit half by A's light, half by B's.
- `toys` — merged into `main` (the owner tried it in the headset and asked to merge): a cheaper
  demo (README wish «Дешевле демонстрация с мячами и кубами»):
  `main.set_objects` sorts the toys by region (A's sheet, the shell, B's sheet: `wh_bIdx`,
  `wh_cIdx`, `main.region_order`) and gives the flat spheres (`wh_fball`); in the curved region
  each candidate is searched alone, in its r/w window and on the cylinder its psi window; hits are
  ordered by place on the path (2 piece + fraction), so no exact path length and the fillet table
  in the balls shaders too; 24 registers (8 waves) instead of 32; the frame split by the stencil
  (`main._update_proxies`, `shaders/stencil_mark*.gdshader`): spheres around the shell and this
  universe's toys mark where the toys' ray tracer runs, the plain one runs elsewhere (a second
  quad, `plain_material`). Model: 5.8 -> 4.5 ms over the speed check's 13 poses, start 4.3 -> 2.9,
  throat sideways 6.2 -> 4.0. The speed check in the headset (72 Hz, no foveation): against main's
  balls shader 0.57 on average (0.64 at the seven places where main's fits in 72 Hz), start
  7.4 -> 3.6 ms, throat sideways 16.6 -> 6.4; the stencil -39% at the start, 0..+2.6% inside the
  shell; with our narrow map 3.0-5.2 ms at all 13 places; the 120 Hz tour 0 missed of 20634. In
  play 144 Hz still falls to SteamVR's half rate, and at 120 Hz near the throat single frames took
  8.5 ms where the tour took 3.5-4 (the tour holds the physics; in play the throat's ball may still
  be falling slowly: not checked). The "stripe" in the throat is fixed here (below, «Rays that go
  round the throat»).
- `menu` — merged into `main` (the owner asked to merge): the GUI as buttons, not a ray (README
  «Что видно в шлеме», «Управление»): the big
  panel pointed at with a ray and pressed with the trigger is gone. `perf_panel.gd` is a hidden
  menu, a list of rows (rate, scale, foveation, its order, gaze dot, gravity, turn, the line,
  the speed check; `toggle`, `move`, `change`, `press`, `back`), and, while it is closed, a line
  low in the view (`strip`: the rate, the verdict, the GPU time, a choice's answer, the speed
  check's progress and result until the menu is opened). Input in `main._menu_input`: Menu (right)
  or View (left) on the Steam Frame's own controller profile, now in the action map
  (`/interaction_profiles/valve/frame_controller_valve`, paths from Valve's Steamworks page «Steam
  Frame Input»: left D-pad as four buttons and View, right A B X Y and Menu), or a left stick click
  (any profile: the generic one has no menu button); the D-pad or the left stick (hysteresis
  0.6/0.3) picks rows and changes values, held they repeat (0.4 s, then every 0.12 s); a value
  takes effect `SETTLE` (0.5 s) later, at once on A, on another row or on closing (stepping
  through rates does not switch the display each step); A on a row with nothing stepped to sets
  the next value (not the rate); B closes. While it is open (`main.menu_active`, the whole frame
  that closes it too) A, B, the D-pad and the left stick are the menu's: no walking, no reset, no
  new ball or cube, no gravity view. Closed, with the Frame's profile, the D-pad down makes a cube
  (left X elsewhere), up/left/right step the gravity view (left Y elsewhere): Valve's remap of the
  generic profile put X and Y there, so the hands do the same as before. Starting the speed check
  closes the menu. Tests: `walking_xr_test.gd` (both profiles, through trackers),
  `openxr_smoke.gd` (the rows under Monado, by the menu's own calls), `grab_test.gd` (the menu
  keeps B, X, the D-pad and A from the hands). Also here, asked by the owner: the cyan circle the
  floor had in the middle of the throat (l = 0, `wh_renderE`) is gone; the white 1 m ring there
  stays. Not yet seen in the headset: whether SteamVR takes
  the Frame profile (the log's `interaction profile` lines) and lets View and Menu reach the app.
- `rim` — performance with toys at the shell's edge and 144 Hz (the owner's log: a ball held at the
  edge gave frames up to 8 ms, 144 Hz barely held anywhere, `process` 7.4-7.8 ms in late frames;
  README «Мячи и кубы»). GPU: the stencil splits the frame in four classes, each pixel to the
  cheapest ray tracer that sees what its ray may meet: 0 plain, 1 the flat universes' toys only
  (`wormhole_balls*_flat`, `WH_FLAT_TOYS`, 12 registers), 2 the shell's toys but those near the eye
  (`wormhole_balls*`, `wh_candMask` clears their bits), 3 all of them (`wormhole_balls*_near`). Marks
  at priorities -3, -2, -1 (values 1, 2, 3; `main._make_marks`, `_update_proxies`): 1 the proxies or
  the whole view as before; 2 `stencil_toys*.gdshader`, passes that know each pixel's ray (as the
  ray tracers make it): a shell toy within reach of the ray's 3D subspace and its l window (from
  `set_objects`) within the l range the path can pass, four toys at a time from vec4 uniforms
  `main._update_near` packs per mark (`wh_mk*`, `_mark_groups`: a loop over toys with indexing
  made the first version cost 0.5 ms a full-view pass by the model, now 0.28); over the shell's
  sphere only its front faces (cull_back), from within it the whole-view quads; 3 the same for
  near toys (the shell's within `NEAR_REACH` 3 m of the head, at most 4, `main._update_near`: a cone
  is narrower than the plane test's band even at 2 m) inside their
  cones, the cones tested first and the rest a branch (0.17 ms outside them)
  (`wh_nearCone`: the space is CAT(1/rho0^2), so a ray meeting a toy of reach rho at distance D is
  within asin(sin(1.02 rho / rho0) / sin(D / rho0)) of the direction to its centre; the direction
  from `WormholeSpace.toward_fast`, a hand's from its own geodesic; `ref/test_near.py` brute-forces
  it). `tests/split_test.gd` (420 poses, ~20 s) compares the split with the whole view under
  `WH_KIND_COLOUR` (what the ray ends on; green: which ray tracer) bit for bit where a toy shows;
  it found a ray going round the cylinder (b = rho0, rounded up) taken for one turning on a
  fillet. 30 frames after `_pick_shader` draw every ray tracer (`WARM_FRAMES`: pipelines compiled
  before they are needed). CPU: `WormholeSpace.geodesic` steps only l, l' and phi in the totally
  geodesic surface of the geodesic's great circle (Clairaut), the rest exact (`geodesic_rk4` kept;
  `tests/geodesic_test.gd`), the head and hands in steps of `STEP_FRAME` 0.1 m, balls held by
  friction fall asleep (`BALL_SLEEP_STEPS`), pairs and hands' pushes by centres found once a step,
  the toys' uniforms only when changed (`_toy_param`): main's scripts 4.8 -> 1.2 ms a frame on
  this x86 (`tests/cpu_test.gd`), logged as `main's scripts` in `refresh:` lines. Model, 13
  poses, the marks counted: a ball held at the chest 6.05 -> 5.01 ms (at the edge 7.66 -> 5.48),
  the demo alone 4.50 -> 4.32 (the start and the throat sideways as before). Tried in the headset:
  "still bad, cubes at the edge do not hold even 72 Hz" (the demo's big cubes set down on the
  fillet at l 4.6, looked at along it: 9.5-10.5 ms with the narrow map; two held there: 15-16 ms),
  and "some balls blink now and then, once, at random moments" (not found: below). Cubes since: the
  curved search sampled all of a cube's bounding ball (2 half), half of it empty space before the
  face. Now a cube is a candidate by its box's support across the subspace (`wh_cubeSup`), its psi
  window from the box's shadow (atan(across / (distance - along))), its three body slabs only (the
  normal's never cuts while half <= 0.4, `BallWorld.MAX_CUBE_HALF`), and its reach (marks, cones,
  windows, the chord's pretest) the cut's radius sqrt(3 h^2 + bend^2) (0.55 at 0.3,
  `BallWorld.cube_reach`, uploaded in `wh_cubeE[5i+4].w`: computed in the shader it took 32
  registers); windows past the nearest hit skip their psi solves. Model, the speed check's scenes:
  two cubes held at the edge 19.7 -> 15.4 ms, cubes on the floor there 7.0 -> 5.7, a ball held
  6.6 -> 6.4, the throat sideways 4.1 -> 3.8; 24 registers. Tried and dropped (model): a skip
  along the path by the box's distance (sphere tracing) and cubes in body coordinates per sample
  (fewer samples, but 32 registers), candidates ranked by distance from the head with a per-ray
  cull of those past the hit (+-1%). `tests/count_dump.gd` (the shader with `WH_COUNT`) counts a
  pixel's samples, the hit object's and its candidates. The blink: `tests/blink_test.gd` (fake HMD,
  both eyes, walking, hands, throws, 240 checks of split against whole) and `split_test.gd -- random
  4000` find nothing, on the build the owner tried too; colours differ between the classes only in
  a few grid pixels (helper lanes of another class's quad). Asked the owner what blinks.
  Then two cubes held: a ray at one lies in the other's plane too (the rays' planes are a pencil
  round the line throat axis - eye), so stencil 3 searched both. Now the mark 3 tests a near cube's
  box as well (`main._near_box`, `wh_nearBox`: flat in the head's normal coordinates, the room's,
  axes carried back along the head's geodesic, each slab grown by D (h + e)(0.07 + 0.017 D), e the
  eyes' real offset + `NEAR_LAG`: `ref/test_nearbox.py`, RK4 against the flat box, the slabs' growth
  at most 0.057 D (h + e) within 1.5 m, 0.081 at 3 m in 1352 cases; `BOX_GROW` is 1.4 times that),
  and stencil 3's ray tracer drops per ray the near toys whose cone or box it misses
  (`WH_NEAR_CULL` in `wh_curved`, from (vl, w) and uniforms per eye, `main._near_cull`, the eye
  picked by the ray's start point by selects: an index, the view index or a mask from varyings took
  32 registers). Model (one eye at the head): two cubes held 16.1 -> 12.4 ms; both eyes of the fake
  HMD, samples a wave (two cubes held / cubes on the floor at the edge): from the head 7.3 / 2.0, per
  eye 6.7 / 1.7, no margins at all (wrong, a bound) 4.9 / 1.1. Then near first: a cube's pixels
  (47% of the view) took 8.1 samples, 4.4 its own: the candidates went by index, the held cubes
  last; stencil 3 now takes the near ones first (`wh_nearAll`), the rest cut at their hit: 6.7 ->
  5.2 a wave in both eyes, model 12.4 -> 11.6 ms; a ball held and cubes on the floor as before.
  `count_dump.gd -- scene split [xr]`
  counts the split frame (xr: both eyes of fake_hmd.gd), `class_share.gd -- scene` the classes'
  shares.
  The builds of 9f0d4f9 and d883b1a print the `refresh:` line's new numbers out of order: there
  "max of X" is the scripts' mean and "main's scripts Y ms avg Z max" their most and the frame's
  budget (fixed after).
- `controls` — the old sketch that `walking`, `throat` and `grab` were split from (on
  `physics` on `refresh-rate`); don't start from it.

Where the README wishes start (wishes without a branch start from `main`):
- stick locomotion on the floor → `main` (smooth stick walking, smooth and snap turn are there);
- free flight in 3D with gravity on/off → `main` (the honest field, `WormholeSpace.potential_grad`,
  and bodies that move in it, `ball_world.gd`);
- pick up and throw, the hand of finite strength, pulling objects like in Half-Life: Alyx → `main`
  (grip grab and throw of balls and cubes on the fast core, the hands on the curved space, merged
  from `throw`; `grab` is the old sketch);
- cubes next to balls, the light in the throat, the demo's cost → `main` (cubes on the fast core;
  the cheaper demo merged from `toys`);
- throat shape, VR-friendly knobs, test scenes → `throat` (throat length and fillet on the right
  stick);
- the menu, its rows, controller buttons for settings → `main` (merged from `menu`: a hidden
  list worked with the D-pad, A and B; the Frame's own controller profile);
- refresh rate and render scale → `main` (the menu's rows are there; the owner wants no automatic way
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
- the grip (on `main`, from `throw`) and `throat`'s: there the right grip held makes the right
  stick's y the fillet, on `main` it grabs. Right B and left X are taken (a new ball, a new cube).
- the hands (on `main`, from `throw`) take two of the shader's 12 ball slots (`BallWorld.MAX_BALLS` 8 + 2). Per frame
  `main._process` steps the free toys first (the hands pushing from last frame's places), then
  places the hands and what they hold (`_update_hands`), then uploads: a toy let go starts from
  the hand, not a frame ahead. Teleports (`place`, `set_pose`, a snap turn) forget the hands'
  recent places (`_forget_motion`), or the jump would be a throw.
- `grab` and `main` (from `throw`) both have a `tests/grab_test.gd`: keep `main`'s.
- the triggers, on `main`: the left one runs; nothing is pointed at any more (the panel became
  the menu, from `menu`). Branches made before it point at the panel with the triggers
  (`perf.point`, `perf.on_plate`): that code is gone on `main`.
- the menu (on `main`, from `menu`): while it is open, A, B, the D-pad and the left stick are its
  (`main.menu_active`): a branch's own buttons must check it too, and stay off the left stick
  click, View and Menu. A new action must be bound in the Frame's profile of the action map as
  well (SteamVR takes that profile when the app offers it: an action missing there gets nothing);
  left X / Y of the other profiles are the Frame's D-pad down / up, left, right. A setting of
  another branch fits the menu as a row (`perf_panel.ROWS`, `_count`, `_current`, `_apply`,
  `_value_text`).
- the right stick: x turns on `main` (its click switches smooth/snap), y changes the throat in
  `throat`; that fits.
- the speed check (`bench.gd`) sets the viewer's pose itself: while it runs (`main.hold`) the
  sticks and A do nothing. `grab` and `throat` add their own buttons: keep them out of it too (`gravity`'s Y, G and its
  menu row are: the menu greys the rows the speed check sets).
- A resets on `main`, in `throat` and `grab`: one reset does all of it.
- left Y shows gravity in `gravity` and in `physics` (the same views; `physics` draws them on the
  old core): keep `gravity`'s, which has them with the balls and cubes too. `gravity` holds
  `physics`'s balls and cubes (`ball_world.gd`) with the cubes drawn on the fast core: `grab` on top
  of `gravity` instead of `physics`; set_balls is now set_objects (balls and cubes, five vectors
  per cube in `wh_cubeE`).
- a throat change with balls (`throat` + `physics`): balls must keep their distance to the
  edge of the curved shell, as the feet do in `set_geometry`.
- a throat change (`throat`) with `main`'s fillet table: the table depends on the shape: after
  `space.set_profile`, `main._upload_fillet_table()` again (3 ms in GDScript on the desktop). The
  same for `gravity`: `set_profile` rebuilds the gravity table, `main._upload_gravity()` sends the
  shader its polynomials again.
- foveation (on `main`) and the render scale: the menu lets one of them be on (the eye-tracked
  map's offsets are in full-size pixels). Its rows sit under the scale's; its split pass is on the
  XR camera's compositor: an effect added there by another branch splits the pass as well. The
  action map has the eye gaze profile (`eye_gaze_pose` on `/user/eyes_ext`). Branches started
  before the merge start with foveation off; merged with `main`, they get it on by default.
- the stencil split (on `main`, from `toys`; on `rim` four classes) with anything that sets uniforms:
  there are several ray tracer materials (`material` with the toys, `plain_material` where none can
  be seen; on `rim` also `flat_material`, `near_material` and the marks' `mark_materials`, which
  read the eye's uniforms and the toys'): a uniform all read goes through `main._param`; the toys'
  own (`wh_ball`...) through `main._toy_param` (`set_objects`; on `rim` it skips unchanged values). The
  shader index of a ball is not its index in `world.balls` (`set_objects` sorts them). Godot
  geometry drawn before the ray tracers must not set the stencil. A changed throat (`throat`):
  `set_objects` again (the sorting and the proxies use `space.h`, `space.Rout`). Balls held in the
  hand (`grab`) are fine: a ray that meets a toy leaves its proxy at least the margin (8 cm, more
  than the near plane's 5 cm) beyond the hit, so the near plane never takes the mark away.
- `fast-rays` with `physics` or `grab`: they set `wh_ball` / `wh_nBall` on the material; with
  `fast-rays` that goes through `main.set_balls`, which also switches to the shader with balls
  (the one without them has no ball code at all and ignores them).

## Hard rule: stereo before headset

Broken stereo physically hurts in a headset. For every headset build, run `tools/test_stereo.sh`
on exactly that source; it must pass (exit 0). The owner takes the build before it finishes
(started first, in the background: above), so the moment it fails, tell the owner at once not
to put that build on, then fix it. If you add things Godot draws next to ray-traced ones, check
they line up the same way.

## Running things

- **Fresh machine:** `tools/setup.sh` downloads Godot 4.7.2 into `tools/.bin` (and links it as `godot` in `/usr/local/bin`), the export templates and the pip packages, and installs xvfb, lavapipe, EGL and Monado with apt if they are missing. A tool you had to install by hand goes into it too.
- **Fresh clone:** run `godot --headless --path godot --import` once before running test scripts with `-s`, or `class_name` types such as WormholeSpace are unknown. `test_stereo.sh` does it itself.
- **Stereo:** `tools/test_stereo.sh` (~5 min alone, ~12 with other tests beside it: the renders run in parallel, one Godot per core, each with its own display and shader cache; the check scene again with foveation on, and those pictures against the ones without).
- **Foveation in the Frame's driver:** `tools/fdm_check.sh` (~10 s): Godot on Turnip over the noop drm-shim, the XR view through `fake_hmd.gd` at 1728² per eye, and the driver's trace (`MESA_GPU_TRACES=print`, `TU_DEBUG=perf`) per render pass: in tiles or not, attachments, tiles. Off: no tiles; split: tiles; on: tiles and one attachment more (the density map).
- **A build for the one-eye check:** an empty file `godot/check` before the export turns the stereo check scene on (`main.CHECK_FLAG`, in the export's include filter, not in git); delete it afterwards.
- **Tracer accuracy:** `python3 ref/test_gpu.py` (~4 min; needs EGL: `libegl1 libegl-mesa0`, which `setup.sh` installs), `ref/test_fast.py`, `ref/test_eye.py`. It prints errors, no verdict: compare them with the same run on the code before a change (`WH_BALLS=0` too: it compiles the shader without balls). `ref/wh.py` `fast` mirrors the shader's curved-region method in float64; keep the two in step.
- **Where the registers go:** `python3 tools/ir3_live.py LOG` (LOG from `KEEP_LOG=... tools/adreno_stats.sh`):
  live register components at every instruction of the program (backward liveness over its
  branches), the peak and the code around it; the uniform loads there (`c<a0.x + N>`) tell which
  uniforms. Half registers count, two to a full component (the register file is shared); shared
  ones (r48-r55) do not. 47 components is the plain shader's 12 registers, 97 the balls shader's 24.
- **What the headset's compiler makes of the shader:** `tools/adreno_stats.sh [scene]` (3 s): Godot on Mesa's Turnip (Adreno 750) over the noop drm-shim, which `setup.sh` builds into `tools/.bin/mesa-fd`; it prints instructions, nops, registers and waves of the ray tracer (Godot compiles it twice: a generic ubershader, then the specialised one). The numbers that matter on the Frame: registers per pixel set the waves at once (48 → 4, 24 → 8, 16 → 12, 13 → 14; at 12 or fewer the compiler runs waves of 128), and the instructions a ray runs. No timings: there is no GPU.
- **Cost without a headset:** `tools/adreno_cost.sh [--check] [--toys] [--gravity 1|2] [source]...` (sources as
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
  `--profile` gives cycles per stretch of code, `--poses "l,yaw,pitch;..."` other poses (the
  throat sideways is the demo's dearest), `--split` the toys as the app draws them (the plain ray
  tracer where the stencil's proxies do not mark; the proxies from `tests/emu_dump.gd`; on `rim`
  the four classes, and the marks 2 and 3 themselves, compiled alone by `adreno_stats.sh --alone`
  (`tests/one_shader.gd`) and emulated with their own uniforms: the model left them out at first,
  and they cost a millisecond inside the shell); with
  `--toys` other sources are timed with their own balls shader (`tools/ab_shaders.sh` copies it).
  The flat inputs' packing (v_eye, v_l, v_n here) is found by matching the picture.
- **Measuring in the headset without the owner walking:** the menu's last row, A (or, in a
  build made with `tools/ab_shaders.sh --auto ...`, the start) runs `godot/bench.gd` (~1 min). A
  frame's cost depends only on what is in view from where, so it goes through scenes of play where
  the headset found frames dear (`godot/play_scenes.gd` `PlayScenes.SCENES`: the demo from the
  start, the edge and outside it facing the throat, the throat sideways, world B at the edge, the
  demo's cubes set down at the edge looked at down and along, two cubes held there, a ball held),
  the viewer and the toys placed and held (`main.hold`), at 72 Hz: this build's ray tracer as in
  play (the menu's foveation) and without foveation (what `tools/adreno_cost.sh` models: its
  default poses are the same scenes, `--poses scenes[:i,j]`), and every ray tracer in the build
  (`godot/shaders/ab/`, not in git: earlier commits, directories, or cost checks empty/flat/
  noshade/noderiv/nogrid/nosky made from the tree; theirs over the whole view, TOYS_BARE) in a
  palindrome order, a `bench:` line per scene (with refreshes missed) and `bench: as in play`. Its
  result (under its row in the menu, and on the line below until the menu is opened): the three
  dearest scenes as in play and the highest rate each leaves room for (within 70% of its budget),
  the comparison, what foveation saves. The toys, pose, rate, scale and foveation come back after.
  Frame times from walking around do not compare between builds: where one looks changes them
  several times. The menu's script also logs a `refresh:` line every second (with where one looks)
  and one per late frame.
- **Pictures against another commit:** render both at many poses with `tests/emu_dump.gd`
  (`... -- out.json "l,yaw,pitch;..." fov plain|balls [shader]`) and diff the PNGs; `edge-120hz`
  matched the main before it within 1/255 at every pose.
- **`split_test.gd` at its own size:** run it at `--resolution 192x192`; at the window's 1280x720
  a few silhouette pixels of the flat universes' balls round differently between two ray tracers
  compiled apart (4 of 21 million on 436 poses), not a split error.
- **Tests:** on `gravity`, `--rendering-method mobile --fixed-fps 60 -s res://tests/gravity_test.gd`
  under xvfb (the field against `ref/test_gravity.py`, Laplace, the shader's polynomials, the views'
  colours) and `python3 ref/test_slice.py` (the arrows' surface against RK4 rays, ~2 min); on `rim`, `--rendering-method mobile -s res://tests/blink_test.gd` (the split in motion through the fake HMD) and `split_test.gd -- random N`; on `main`, `--xr-mode off -s res://tests/refresh_rate_test.gd` (the rate meter, the verdict, the GPU clock), `tools/test_openxr.sh` (the panel and its buttons) and `--fixed-fps 60 -s res://tests/walking_test.gd` / `walking_xr_test.gd` (the sticks, from keys and from controller trackers); each branch's own, `--fixed-fps 60 -s res://tests/<name>_test.gd` (`throat`, `physics`, `grab`).
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
- **Logs on the Frame:** `~/.local/share/godot/app_userdata/Wormhole VR/logs/`; `tools/frame_logs.bat` fetches them. Screenshots: `tools/frame_screens.bat [days]` zips Steam's and `~/Pictures`' into Downloads as `wormhole_vr_screenshots.zip` with `where.txt`, the paths they had; finding none, it lists fresh images elsewhere in the home. On the Frame they are in `userdata/<id>/760/remote/<the 64-bit game id>/screenshots`: 1920×1080 JPEGs of one eye's view with the panel in it, a few hundred kB each. `application/run/flush_stdout_on_print` is on, or the running app's log lost its last lines. The desktop window's V-Sync mode Disabled is not available there (Godot falls back to Enabled), and the app still reached 144 Hz.
- **Signals of the OpenXR interface.** A GDScript lambda connected to an `OpenXRInterface` signal by the panel corrupted the heap at exit (under Monado); a method callable did not. `tools/test_openxr.sh` fails on a crash at exit.
- **SceneTree test scripts.** In them `main._ready` has not run during `_initialize`; touch main's nodes from `_process` (frame 2 or later). Settings applied too early silently do nothing.
- **Software-Vulkan timings** are only good for ratios, and not for the shader's inner costs: halving the curved-region Simpson steps changed lavapipe's frame by 1%, while on the Frame the curved-region rays double the frame. `tests/perf.gd` `near` / `away` (6.5 m from the centre, facing it / away) separate them. For the Frame's own compiler use `tools/adreno_stats.sh`.
- **Registers are taken by code no pixel runs.** The GPU reserves a shader's registers for its heaviest point, so the movable balls' code (12 unrolled candidate loops with bisections) held the plain scene at 48 registers and 4 waves with no balls in it. Loops over balls run to `wh_nBall` (a constant bound with `break` is unrolled 12 times), candidates are bit masks, not arrays, and the scene without balls uses the shader built with `WH_NO_BALLS`. On Turnip a 4-wave shader is a slow one, whatever it computes.
- **Derivatives in the shader** (`fwidth` for the grid lines) are only defined in uniform control flow: `wh_render` computes the lines' coordinates for every pixel and their `fwidth` once, after the trace.
- **Godot shading language** reserves `E`, `PI`, `TAU` as built-in constants: a local variable `E` is a compile error in Godot that GLSL (`ref/`) accepts. `tools/test_stereo.sh` and `adreno_stats.sh` fail on shader errors.
- **Render scale and the stereo test.** At a 3D render scale below 1 the bilinear upscale blends the balls' edges with the background, and the one-colour red threshold of `tools/compare` then shifts the shaded ray-traced ball by 0.2–0.4 px against Godot's flat red one. With `SCALING_3D_MODE_NEAREST` the whole suite passes at 80% within 0.02 px: the geometry is exact, test a scale that way.
- **Balls in the shader.** A ball far from the throat must not be a candidate in the curved-region integrator (`wormhole_core`), or every ray through the throat samples it finely. A ball around the eye (the avatar's head) still does that inside the throat.
- **The one-eye check in the headset** is what catches problems only the real device has. Run it after any change to rendering.
- **Controllers.** Before `menu` our action map had no profile of the Steam Frame's own (Godot 4.7.2 knows it, `/interaction_profiles/valve/frame_controller_valve`, extension `XR_VALVE_frame_controller_interaction`, which Godot asks for by itself). On our Frame (SteamVR 2.18.2) the log's `interaction profile` lines showed both controllers as `/interaction_profiles/khr/generic_controller`; its bindings (thumbstick, trigger, `primary/click` for A) were what the headset used. Valve's page «Steam Frame Input» (Steamworks docs) lists the Frame profile's paths: left `dpad_up/down/left/right`, `view`, `system`, `bumper`; right `a`, `b`, `x`, `y`, `menu`, `system`, `bumper`; both `squeeze` (value, click, touch), `trigger`, `thumbstick`, `grip/pose`, `aim/pose`, `output/haptic`. SteamVR, it says, always takes the Frame profile when the app suggests it, else the generic one, else Touch, remapped: Touch's menu is View, its upper button (B / Y) all three upper buttons (D-pad left, up, right / X, Y, B). Since `menu` (merged) the map has the Frame profile (paths from that page only); `walking_xr_test.gd` checks the bindings of each profile. Monado has no such extension: Godot leaves the profile out there, silently. The default font (Open Sans) has no arrows or triangles (‹ › « » it has): `perf_panel.gd` draws its arrows as meshes. One path a runtime rejects drops that whole profile's bindings: Monado rejected `grip_surface/pose` (the palm pose) on Touch, and then no Touch input worked at all. The palm pose is unused here and out of the map.
- **GDScript in a frame runs 2-3x slower than in a loop:** the frame's rendering evicts the
  interpreter's code and data from the caches (BallWorld.step: 170 us hot, 400 with the caches
  flushed between calls, 440-500 in frames). Time scripts in frames (`tests/cpu_test.gd`'s first
  line, `main.cpu_us`), not in a loop. `Performance.TIME_PROCESS` is the second's longest frame.
- **Logs from a release build.** Without `application/run/flush_stdout_on_print` (on in `project.godot`) an export buffers `print()`, and an abort on quit loses every printed line from `godot.log`, the headset's too.
- **Tests with `fake_hmd.gd` abort at exit** (status 134) unless the interface and trackers are taken down first; `walking_xr_test.gd` does it, so its exit status means something.
  With four Godots at once it sometimes hangs at exit after all its checks passed (`main` too: 2 of
  12 runs, under `timeout` status 124); run alone, it exits.
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
- **The cost model misses the balls shaders by ~1.8x** (toys: 4.5 ms over the speed check's poses,
  8.0 in the headset; main's balls shader 5.8 against 13.8), while the plain shader is within 5%.
  Its ratios are too modest as well (0.78 promised, 0.57-0.64 measured). Unknown why (memory waits,
  waves, divergence, the safe-constlen program?): don't trust its absolute numbers for them.
- **A variant over the frame's budget in the speed check** (above 13.9 ms at 72 Hz) halves the
  rate: SteamVR fills in frames on the same GPU, and it reads more than it costs, and so does the
  segment after it (first segments 3.4 ms dearer than the second ones). Compare at places where
  every variant fits.
- **Rays that go round the throat** (|vl| below ~2e-4 on the cylinder, a column near where the
  view crosses vl = 0, looking sideways inside the throat) were the owner's "stripe": white
  dashes along the throat at the eye's own l, through the floor, the cube and the ball. Two float32
  losses: 1 / sqrt(1 - wc^2) with 1 - wc^2 a difference of near-equal numbers (off by half: the
  floor's l off by mm, and the grid drew a line at the jump); `rho0^2 - b^2 = (rho0 - b)(rho0 + b)`
  with `rho0 - b = rs vl^2 / (1 + wn) - (rs - rho0)` has no cancellation. And the balls shader's hit
  key 2 piece + fraction: the cylinder's fraction there is ~1e-5, and 2 + it kept a tenth of its
  digits (the angle round the throat off by radians); piece B now goes without an offset (keys
  A -2.., B 0.., C 2.., the edge 4). Dashed, because no pixel's ray has vl exactly 0: the column's
  rays pass it closer or farther. The reference's and the emulator's cameras never had a pixel
  that close (|vl| ~ 1e-3, where the error is small): a pose at an odd width (the middle column
  at vl = 0 exactly) or the owner's own pose finds such things.
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
- **Moving objects in the curved region: chords, not bisection.** The ray is sampled; between two
  samples the chord in R^4 (in the ray's 3D subspace span(e1, e2, e_w)) is tested against each
  ball and box, and the path's point at the chord's entry is the hit if it lies within the chord's
  sag of the object. Sampling alone lost a cube's bottom edge on the floor (the ray met the floor
  before the next sample) and gave ragged silhouettes; an unchecked chord of a ray that winds
  round the throat (samples spread out) cut across a cube the path passes by. The registers:
  testing a box loads its four axes; unrolled, the compiler loaded all of them and the centre at
  once (117 live, 32 registers): a loop it cannot unroll (`k < 4 + min(wh_nCube, 0)`), the chord in
  three coordinates, and dot(centre, axis) uploaded with the axes (one index base) took it to 24.
- **Moving objects cost per ray, not per object in view.** A ball lying in the middle of the throat,
  seen from the start, is near the plane of every ray (all of them hold the eye-centre line), so
  every ray through the shell had it as a candidate and sampled its whole path at a third of the
  ball's size: the demo cost 51 ms a frame by the model (`main`'s ball shader with its balls: 16).
  Now only the parts of the path within reach in r and in w are sampled (the chord distance in R^4
  is at least both; on a fillet both grow with the angle, so the w bounds are r bounds), the
  chord tests loop over the candidates' bits (`findLSB`: a test a predicate skips still takes its
  cycles), a box's chord test first checks its bounding ball, the flat loops keep only the
  nearest one's distance and index (the whole hit record updated per candidate was half their
  time), and each universe's balls and cubes have a bounding sphere (`wh_bound`, `set_objects`):
  5.2 ms over four poses where `main`'s plain shader takes 3.3. Tried and dropped: ordering the
  hits by the fog's length estimate (monotonic along the path, so the order stays right) to take
  the fillet table: the estimate's division at every sample cost more than the table saved.
- **A turning ray's turning point was 0 / 0** in `wh_filMom` (regime 1, `t / (z + zlo)` at t = 0,
  z = zlo = 0: rays that turn in the fillet's outer half). The floor's Newton solve never lands
  there exactly, but the toys' search samples at q = 0 and 1 of each fillet piece: NaN there made
  every later chord NaN (`tc < 0 || tc > 1` is false for NaN), and a toy straddling the shell's
  edge showed a crack where those rays passed it. Now `z - zlo`. `ref/test_gpu.py`'s poses never
  had a toy near such a turning point; a scan of viewpoints around a ball at the edge did (82 of
  516 ball pixels lost against RK4).
- **The toys' search on a fillet** was bounded by the r and w windows only (psi only said whether
  to search): a ray grazing the shell near its edge stays within them for metres, and a ball held
  there (near the eye: a candidate for a third of the rays) cost the frame 3.5x by the model. The
  psi window's ends are now solved for z (`wh_filSolve`, two Newton steps, one copy of the code by
  a loop bound the compiler cannot see), 5e-3 rad of margin; 24 registers still, the demo's
  frames as they were. Single silhouette pixels flip either way (the sampling's phase moved).
- **`tools/adreno_cost.py` took the first pose's uniforms for every pose:** right for the demo's
  toys at rest, wrong for toys that move with the viewer. With `--hands` / `--held` (emu_dump.gd
  `+hands` / `+held`) each pose has its own (`Shader.set_uniforms`).
- **Godot prints shader float constants with 14 decimals:** `1e-30` and `1e-20` become 0.0
  (`max(x, 1e-30)` compiles to `max(x, 0.0)`); `1e-12` survives. GPUs' `max`/`min` return the
  other operand for a NaN, which hides most of it (the emulator now does the same: `np.fmax`).
- **ir3's prog N/2 is unused.** A fragment shader with more than 100 vec4 of constants (the ball
  shaders: 152-180) is compiled twice, the second time ("safe constlen") reading the uniforms from
  memory with `ldc`, at 32 registers. Turnip runs that one only if the pipeline's stages need more
  than 512 vec4 in all (`ir3_trim_constlen`); ours need ~200 (Godot's vertex shader 44), so the /1
  runs. `adreno_cost.py` takes the /1, `adreno_stats.sh` marks the /2 "unused".
- **Uniform arrays at a computed index** compile to `mova a0.x` + `c<a0.x + N>`, with the index
  already multiplied by 4 in the code (`shl.b ..., 2`): a0.x counts components. a7xx's `shlm`,
  `shrm`, `shlg`, `shrg` take the shift amount first (`(src2 << src1) & src3`, Mesa
  `isa/ir3-cat3.xml`). The emulator had both wrong until the ball shader used them.
  `sad.s32 a, b, c` with no flags is Mesa's iadd3, a + b + c (`ir3_compiler_nir.c`), not
  |a - b| + c: an ivec4 array read at a computed component had the emulator read the wrong toy
  until fixed. `adreno_cost.py --check` emulates the material of stencil 2 with `wh_candMask` -1:
  the picture is the split's, which draws the near toys that material leaves out.
- **The near cull and the registers.** A mask of near toys made per pixel before `wh_curved` (from
  flat varyings, even used at once) or the view index passed into it took stencil 3's ray tracer to
  32 registers; the same tests inside `wh_curved`, from the ray's (vl, w) and uniforms only, kept
  24. Custom functions can't read `VIEW_INDEX` in Godot. Check multiview programs with
  `tools/adreno_stats.sh plain_xr` (`tests/perf.gd` through `fake_hmd.gd`): Godot compiles the
  specialised program (the smallest `prog`) for each.
- **A toy's samples must not depend on the search's order.** A window cut at the nearest hit so
  far was divided into its N samples over the cut part: in another order of the candidates (stencil
  3's near ones first) the samples moved and single pixels of a ball's edge flipped between ray
  tracers (`split_test.gd -- random 2000`: 10 of 17 million). The samples are placed over the whole
  window now and the search stops after the first one past the hit.
- **The curved search's registers are on a knife's edge (24).** One sqrt per candidate (a cube's
  reach from its half size) or one int carried through the sample loop (a skip's step) took it to
  32: the compiler holds such values through the search. Work them out on the CPU and read them
  from a uniform (`wh_cubeReach`: a free slot of `wh_cubeE`), and check `adreno_stats.sh plain
  --shader res://shaders/wormhole_balls.gdshader` after every change there.
- **A view's code costs its shader even when off.** The gravity arrows (a crossing carried through
  the trace) took the shader from 12 to 16 registers (waves of 64); with one shader for the floor
  view and the arrows, switched by a uniform, the floor view cost 3.94 ms by the model, as its own
  shader 3.68 (`main` 3.51).
- **The fog's path length** only needs ~5%: r²/b × psi with r at the weight's mean tau is within
  1.5% here; dropping the exact polynomial took the plain shader from 13 to 12 registers. The
  balls shader orders its hits by place on the path (2 piece + fraction of it, monotone along the
  ray) instead, so it needs no exact length either.
- **ir3 turns an `if` into selects** (if-conversion) even around a square root and a dozen
  instructions: every lane then pays for it. A loop of one pass with a bound the compiler cannot
  see (`for (int k = 0; k < 1 + min(wh_nBall, 0); k++)`) stays a branch, and waves whose lanes all
  fail skip it (the flat balls' root: -3% where they are in view).
- **ir3 does not hoist loop-invariant code (no LICM), but merges equal expressions (CSE).** A value
  computed before a loop and used in it is held through it; computed where used (from values held
  anyway) it is not: that, not new math, took the balls shader from 32 to 24 registers. Computing
  `cos(tot.x)` again after the search was merged with the one before it and held through; the
  floor test from the half angle (a different expression) let it go.
- **The stencil in Godot 4.7.2** (`stencil_mode read|write, compare_..., ref` in a spatial
  shader) works on the Mobile renderer, multiview and lavapipe. Opaque draws follow
  `render_priority`, lower first (the proxies at -1 mark before the quads at 0; on `rim` -3, -2, -1). A MeshInstance3D
  whose ShaderMaterial has no shader yet is drawn and compiled with Godot's default lit material
  (an 8700-instruction program: adreno_stats.sh then picked it): make such a node only once its
  shader is known.
