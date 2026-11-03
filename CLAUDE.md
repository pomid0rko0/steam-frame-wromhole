# Notes for agents working on this repo

How to work here. What is where: README.md (Russian), «Устройство». What a change to a part must
keep and what was learnt about it: the comment at the top of its file.

## The owner's rules

- **The owner** (GitHub `pomid0rko0`) speaks Russian; answer in Russian. They have a Valve Steam
  Frame (standalone VR headset, SteamOS), a Windows 11 PC and an Android phone on one Wi-Fi (often
  the phone's hotspot); SSH into the Frame takes a password.
- **You run** on the Frame, in a VSCodium outside Flatpak (`~/Applications/VSCodium`; inside the
  Flatpak `flatpak-spawn --host` is refused), or in a cloud session (an Ubuntu container, no
  headset), while the owner wears the headset. The tools find out where they run.
- **Builds:** `tools/export.sh` puts the build where the headset takes it; in a cloud session attach
  its zip to the chat; `--pc-windows` makes the build that runs on the owner's PC and streams to the
  headset (README, «Запуск»). CI's run of a pushed commit has the same zips (README, «Проверки»):
  link the run too. Say what to look at. **Never start the app, SteamVR, `vrcmd` or any window yourself:** it
  takes the view the owner is in.
- **The owner can't judge test images or numbers:** verifying is your job. What they check in the
  headset is a yes/no they can see; after any change to rendering, the one-eye check (README.md).
- **Tests stay off the headset:** on the Frame whatever runs Godot or opens a GPU goes through
  `tools/box.sh` (its top says why and how); never start `tools/.bin/godot` on the Frame without it.
- **One wish per chat,** on a branch you name yourself, started from `origin/main` after `git fetch`
  (a cloud session's local `main` can be days old) or the branch the wish's issue gives; not the
  branch a cloud session makes for itself (`claude/…`, `ccr-…`). The owner allows pushing to the
  branch you name. The name says what the branch does, verb first, in as few lowercase English
  words joined by hyphens as say it (`add-throat-knobs`, `fix-cube-tearing`,
  `speed-up-zone-edge`); the same action takes the same verb. If origin already has a branch by
  that name, add what this one does differently, or a number (`speed-up-lens-2`), rather than a
  synonym.
- **`main` and versions:** `main` is what the owner checked in the headset; versions are the
  owner's: their button in GitHub's Actions tags such a commit and CI releases it (README,
  «Проверки»), its notes the titles of the PRs merged since the last version. `main` takes only
  PRs, each squashed into one commit once CI's «Все проверки» passed on a branch up to date with
  `main` (its ruleset): nothing is pushed to `main` itself. A PR that changes what the headset runs
  (`godot/` but `godot/tests/`, `tools/setup.sh`, `tools/export.sh`) the owner merges, or you when
  they say so in the chat; any other you merge yourself then.
- **A PR's title is its line in those notes,** which the owner reads: in Russian, what changes for
  the person in the headset (what they see or can do, what got faster), not how it is done; a PR
  that changes nothing in the headset says what it changes (tests, tools, docs). When what the branch
  does changes, the title changes with it. The description: what to check in the headset (a yes/no
  they can see), what the tests and CI found, what is left. The two are the PR's commit in `main`.
- **CI checks every push** (README, «Проверки»): both builds and every test, shared out over seven
  machines (the stereo test in parts, `tools/stereo_parts.txt`), on exactly the commit pushed; a
  branch that differs from `main` only in Markdown and `docs/` gets none, as nothing reads them. Push
  what you deliver; that run is the check of record, also of the tests you didn't run yourself.
  Watch it: in a cloud session subscribe to the PR, whose activity brings CI's failures; on the
  Frame `gh run watch`. A red run is yours to fix.
- **Docs say what is true now.** README, `docs/` and code comments describe the code as it is: no
  history (git and the PRs keep it), no versions, numbers only as measured on the current code, with
  the tool or test that gives them. A change that makes a statement or a number stale fixes or
  removes it in the same branch.
- **Docs don't retell the code.** README and `docs/` hold only what the code can't say: what the
  project is, how to run, install and check it, the maths.
- **Wishes and bugs are the repository's issues,** in Russian, first what the person in the headset
  sees or can do, then how. Labels: the section, the difficulty (просто, отладка, исследование),
  ошибка, скорость; each with its colour and meaning in `.github/labels.json`, which the Labels
  workflow applies on `main` (a new label goes there). A big one's steps are its sub-issues. The
  owner's reports from the headset come through the form «Ошибка в шлеме»
  (`.github/ISSUE_TEMPLATE/headset-bug.yml`): read its build and log first. A PR that does one says
  `Closes #N` in its description; a bug or a wish found and not done goes into an issue of its own.
  An issue names the code as it is: a branch that renames or changes what an open issue names
  fixes that issue too (search the issues for the name). An issue you write ends with
  «🤖 *Написал Claude (Claude Code); на GitHub показан от имени владельца.*»: GitHub shows it as the
  owner's and drops the usual footer from an issue's body. A comment gets that footer from GitHub
  itself: add nothing to it.
- **A number's source, by its meaning:** before writing a number, check what exactly the counter,
  test or tool measures and in what unit, not only that it prints that number.
- **No work is worth anything by itself.** Nothing is kept only because it was here before you or
  the owner came: what is in the way goes out, and when you can't get further, try something new and
  ignore what is here. Look for the best way as if starting fresh and take it even if it replaces
  what exists, up to writing the project anew. Nothing is kept for compatibility: carry along
  everything that depends on a change in the same branch and migrate what is stored. The checks
  still apply.
- **Make slow frames cheaper without giving anything up,** and without counting on anything
  staying as it is now.
- **The maths isn't fixed either.** The wormhole's shape and metric, the equations of motion,
  light and gravity, the methods that solve them and their error budgets can all be revised to make
  frames cheaper, like the code.
- **A rule in the way:** say so to the owner and propose a replacement; don't work around it
  silently, and don't change a rule without them.
- **Long runs in the background, the build at once.** The owner checks builds without waiting for
  the tests, the stereo test included: once the code for a build is in place, commit and push it
  (CI starts every test on it) or start `tools/test_stereo.sh` in the background, export and deliver
  the build, say the tests still run. On the Frame let CI run them: `tools/box.sh` gives its tests
  one core. Every run of minutes goes to the background; report and fix what it finds afterwards. A run reads
  the code from disk while it goes: run it from your task's worktree in `.wt/<branch>` (`tools/box.sh`
  says how), never from the tree you edit.
- **Read the comment at the top of every file you change, and main.gd's:** the parts, the order of
  a frame, the rules for a new button.

## Hard rule: stereo before headset

Broken stereo physically hurts in a headset. Every headset build gets `tools/test_stereo.sh` on
exactly its source, and it must pass (exit 0): here, or in CI's run of the commit the build names
(`tools/export.sh` puts it in the name; a `+` after it means `godot/` differed from that commit, and
CI's run is not on its source). The owner may take the build before the run ends: the moment it
fails, tell them at once not to put that build on, then fix it. CI deletes the builds of a run whose
stereo test failed, but not one already downloaded. Anything Godot draws next
to ray-traced things must line up the same way, and the stereo test must check it.

## Commands

In a cloud session run `tools/setup.sh` once at the start: it only links `tools/.bin` to the
environment's install; if it starts downloading or building, tell the owner which step the
environment lacks. On the Frame there is nothing to run: `tools/box.sh` sets its container up by
itself. Install nothing by hand: what the work needs goes into `setup.sh`.

Runs of minutes, so in the background (the rule above): `tools/test_stereo.sh`, `tools/test.sh`,
`tools/test_openxr.sh` (alone: its top says why), `python3 ref/test_gpu.py`, `tools/test_box.sh` (on
the Frame only). Under a minute: `tools/export.sh`, `adreno_stats.sh`, `python3
ref/test_gravity.py`.

- **Before a Godot run of your own with `-s`** (the tools import by themselves when a script
  changed): `tools/box.sh godot --headless --path godot --import` in the tree you run it from.
- **Speed** is measured in the headset with the speed check (`godot/bench.gd`).
- **GitHub:** on the Frame git pushes as the owner through `gh` (`~/.local/bin/gh`,
  `gh auth setup-git`) and commits as `Claude <noreply@anthropic.com>`. In a cloud session branch
  pushes go through the session's proxy and tag pushes are refused.
- **CI** (`.github/workflows/ci.yml`) runs all of the above but `test_box.sh`. Its runs and logs:
  in a cloud session the GitHub MCP's `actions_list`, `actions_get` and `get_job_logs`; on the Frame
  `gh run view --log-failed`. Its tests run in the image of `tools/Containerfile` (named by
  `tools/box_image.sh`): a change to it or to `setup.sh` makes CI build a new one first, minutes
  longer.
