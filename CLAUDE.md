# Notes for agents working on this repo

How to work here. What the project is and how to run, install and check it: README.md (Russian).
The maths and the owner's wishes: `docs/`. How each part works, what a change to it must keep and
what was learnt about it: the comment at the top of its file.

## The owner's rules

- **The owner** (GitHub `pomid0rko0`) speaks Russian; answer in Russian. They have a Valve Steam
  Frame (standalone VR headset, SteamOS), a Windows 11 PC and an Android phone on one Wi-Fi (often
  the phone's hotspot); SSH into the Frame takes a password.
- **You run** on the Frame, in a VSCodium outside Flatpak (`~/Applications/VSCodium`; inside the
  Flatpak `flatpak-spawn --host` is refused), or in a cloud session (an Ubuntu container, no
  headset), while the owner wears the headset. The tools find out where they run.
- **Builds:** `tools/export.sh` puts the build where the headset takes it; in a cloud session attach
  its zip to the chat. Say what to look at. **Never start the app, SteamVR, `vrcmd` or any window
  yourself:** it takes the view the owner is in.
- **The owner can't judge test images or numbers:** verifying is your job. What they check in the
  headset is a yes/no they can see; after any change to rendering, the one-eye check (README.md).
- **Tests stay off the headset:** on the Frame whatever runs Godot or opens a GPU goes through
  `tools/box.sh` (its top says why and how); never start `tools/.bin/godot` on the Frame without it.
- **One wish per chat,** on a branch you name yourself, a short English word no branch in origin
  has yet, started from `main` or the branch `docs/wishlist.md` gives for the wish; not the session's
  `claude/…` branch. The owner allows pushing to the branch you name.
- **`main` and versions:** `main` is what the owner checked in the headset; versions are git tags
  the owner sets on such a commit.
- **Docs say what is true now.** README, `docs/` and code comments describe the code as it is: no
  history (git and the PRs keep it), no versions, numbers only as measured on the current code, with
  the tool or test that gives them. A change that makes a statement or a number stale fixes or
  removes it in the same branch.
- **Docs don't retell the code.** README and `docs/` hold only what the code can't say: what the
  project is, how to run, install and check it, the maths, the wishes.
- **A number's source, by its meaning:** before writing a number, check what exactly the counter,
  test or tool measures and in what unit, not only that it prints that number.
- **"Done" after a cold read:** before calling docs done, have an agent without this chat's context
  check every statement against the code; fix what it finds and repeat until a read finds nothing
  substantive.
- **Don't anchor on what is here.** Look for the best way as if starting fresh and take it even if it
  replaces what exists, up to writing the project anew. Nothing is kept for compatibility: carry
  along everything that depends on a change in the same branch and migrate what is stored. The
  checks still apply.
- **Make slow frames cheaper without giving anything up,** and without counting on anything
  staying as it is now.
- **A rule in the way:** say so to the owner and propose a replacement; don't work around it
  silently, and don't change a rule without them.
- **Long runs in the background, the build at once.** The owner checks builds without waiting for
  the tests, the stereo test included: once the code for a build is in place, start
  `tools/test_stereo.sh` in the background, export and deliver the build, say the tests still run.
  Every run of minutes goes to the background; report and fix what it finds afterwards. A run reads
  the code from disk while it goes: run it from your task's worktree in `.wt/<branch>` (`tools/box.sh`
  says how), never from the tree you edit.
- **Read the comment at the top of every file you change, and main.gd's:** the parts, the order of
  a frame, the rules for a new button.

## Hard rule: stereo before headset

Broken stereo physically hurts in a headset. Every headset build gets `tools/test_stereo.sh` on
exactly its source, and it must pass (exit 0). The owner may take the build before the run ends: the
moment it fails, tell them at once not to put that build on, then fix it. Anything Godot draws next
to ray-traced things must line up the same way, and the stereo test must check it.

## Commands

In a cloud session run `tools/setup.sh` once at the start: it only links `tools/.bin` to the
environment's install; if it starts downloading or building, tell the owner which step the
environment lacks. On the Frame there is nothing to run: `tools/box.sh` sets its container up by
itself. Install nothing by hand: what the work needs goes into `setup.sh`. Each tool's top says
what it does and how to call it.

| command | time in the cloud; on the Frame where given |
|---|---|
| `tools/test_stereo.sh` | ~5 min alone, more beside other runs; ~11 min on the Frame |
| `tools/test.sh [name...]` | 1–3 min; ~2 min on the Frame |
| `tools/test_openxr.sh` | ~3 min, alone (its top says why) |
| `tools/export.sh [--check] [label]` | ~40 s |
| `python3 ref/test_gpu.py`, `ref/test_eye.py` | ~4 min, ~1.5 min |
| `python3 ref/test_fast.py`, `test_slice.py`, `test_gravity.py` | seconds to 2 min |
| `tools/fdm_check.sh`, `adreno_stats.sh`, `ir3_live.py`, `same_programs.py`, `ab_shaders.sh` | seconds |
| `tools/adreno_cost.sh` | ~1 min per source |
| `tools/test_box.sh` (the Frame only) | ~5 min |

- **Before a Godot run of your own with `-s`** (the tools import by themselves when a script
  changed): `tools/box.sh godot --headless --path godot --import` in the tree you run it from.
- **Speed** is measured in the headset with the speed check (`godot/bench.gd`); the cost model
  (`tools/adreno_cost.sh`) only compares variants.
- **GitHub:** on the Frame git pushes as the owner through `gh` (`~/.local/bin/gh`,
  `gh auth setup-git`) and commits as `Claude <noreply@anthropic.com>`. In a cloud session branch
  pushes go through the session's proxy and tag pushes are refused.
