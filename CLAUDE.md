# Notes for agents working on this repo

The owner (GitHub `pomid0rko0`) speaks Russian: answer in Russian. What the project is, how to run
and check it: README.md (Russian); what is where: its «Устройство». Before changing a file, read
the comment at its top (what a change to it must keep, what was learnt about it), and
`godot/main.gd`'s: the parts, the order of a frame, the rules for a new button.

## Hard rule: stereo before headset

Broken stereo physically hurts in a headset. Every headset build gets `tools/test_stereo.sh` on
exactly its source, and it must pass (exit 0): here, or in CI's run of the commit the build names
(`tools/export.sh` puts it in the name; a `+` after it means `godot/` differed from that commit,
and CI's run is not on its source). The owner may take the build before the run ends: the moment
it fails, tell them at once not to put that build on, then fix it. CI deletes the builds of a run
whose stereo test failed, but not one already downloaded. Anything Godot draws next to ray-traced
things must line up the same way, and the stereo test must check it.

## The owner and the headset

- **What they have:** a Valve Steam Frame (standalone VR headset, SteamOS), a Windows 11 PC and an
  Android phone on one Wi-Fi (often the phone's hotspot); SSH into the Frame takes a password.
- **You run** on the Frame, in a VSCodium outside Flatpak (inside it `flatpak-spawn --host` is
  refused), or in a cloud session (an Ubuntu container, no headset), while the owner wears the
  headset. The tools find out where they run.
- **Never start the app, SteamVR, `vrcmd` or any window yourself:** it takes the view the owner is
  in. On the Frame whatever runs Godot or opens a GPU goes through `tools/box.sh` (its top says why
  and how); `tools/.bin/godot` never runs there without it.
- **Builds:** `tools/export.sh` puts the build where the headset takes it; in a cloud session
  attach its zip to the chat. `--pc-windows` makes the build that runs on the owner's PC and
  streams to the headset (README, «Запуск»). CI's run of the pushed commit has the same zips: link
  it too. Say what to look at.
- **Verifying is your job:** the owner can't judge test images or numbers. What they check in the
  headset is a yes/no they can see; after any change to rendering, the one-eye check (README,
  «Проверки»).
- **The build at once, long runs in the background.** The owner checks builds without waiting for
  the tests, the stereo test included: once the code for a build is in place, commit and push it
  (CI starts every test on it) or start `tools/test_stereo.sh` in the background, then export and
  deliver the build and say the tests still run. Every run of minutes goes to the background;
  report and fix what it finds afterwards. A run reads the code from disk while it goes: run it
  from your task's worktree in `.wt/<branch>` (`tools/box.sh` says how), never from the tree you
  edit. On the Frame let CI run the tests: `tools/box.sh` gives them one core.

## Commands

In a cloud session run `tools/setup.sh` once at the start: it only links `tools/.bin` to the
environment's install; if it starts downloading or building, tell the owner which step the
environment lacks. On the Frame there is nothing to run: `tools/box.sh` sets its container up by
itself. Install nothing by hand: what the work needs goes into `setup.sh`.

- **Runs of minutes**, so in the background: `tools/test_stereo.sh`, `tools/test.sh`,
  `tools/test_openxr.sh` (alone: its top says why), `python3 ref/test_gpu.py`, `tools/test_box.sh`
  (on the Frame only). **Under a minute:** `tools/export.sh`, `tools/adreno_stats.sh`,
  `python3 ref/test_gravity.py`.
- **Before a Godot run of your own with `-s`** (the tools import by themselves when a script
  changed): `tools/box.sh godot --headless --path godot --import` in the tree you run it from.
- **Speed** is measured in the headset with the speed check (`godot/bench.gd`).
- **CI** (`.github/workflows/ci.yml`; README, «Проверки») checks every push, on exactly the commit
  pushed: all the builds and all of the above but `test_box.sh`, shared out over eleven machines
  (the stereo test in parts, `tools/stereo_parts.txt`). A branch that differs from `main` only in
  Markdown and `docs/` gets none, as nothing reads them. The tests run in the image of
  `tools/Containerfile` (named by `tools/box_image.sh`): a change to it or to `setup.sh` makes CI
  build a new one first, minutes longer. Push what you deliver: that run is the check of record,
  also of the tests you didn't run yourself. Watch it: in a cloud session subscribe to the PR,
  whose activity brings CI's failures, and read logs with the GitHub MCP's `actions_list`,
  `actions_get`, `get_job_logs`; on the Frame `gh run watch` and `gh run view --log-failed`. A red
  run is yours to fix.
- **GitHub:** on the Frame git pushes as the owner through `gh` (`~/.local/bin/gh`,
  `gh auth setup-git`) and commits as `Claude <noreply@anthropic.com>`. In a cloud session branch
  pushes go through the session's proxy and tag pushes are refused.

## Branches, PRs, issues

- **One wish per chat, on its own branch,** started from `origin/main` after `git fetch` (a cloud
  session's local `main` can be days old), or the issue's branch if it has one
  (`git branch -r --list 'origin/*/issue-<N>-*'`); not the branch a cloud session makes for itself
  (`claude/…`, `ccr-…`). The owner allows pushing to it. Its name follows
  [Conventional Branch](https://conventionalbranch.org/), `feat` and `fix` as in the commits; the
  description is the wish's issue (one said in the chat gets its issue first) and a few English
  words: `feat/issue-47-throat-shape`, `fix/issue-43-cube-tearing`. Its commits follow
  [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), the description in
  Russian, like the PR's title.
- **A PR's title and description become its one commit in `main`;** the title is also its line in
  the version's notes, which the owner reads. The title: a Conventional Commit's header, its type,
  then in Russian what changes for the person in the headset (what they see or can do, what got
  faster), not how it is done (`feat: форма горла в меню`); a PR that changes nothing in the
  headset says what it changes (tests, tools, docs). When what the branch does changes, the title
  changes with it. The description: what to check in the headset (a yes/no they can see), what the
  tests and CI found, what is left, and `Closes #N` for the issue it does.
- **`main`** is what the owner checked in the headset. It takes only PRs, each squashed once CI's
  «Все проверки» passed on a branch up to date with `main` (its ruleset); nothing is pushed to
  `main` itself. A PR that changes what the headset runs (`godot/` but `godot/tests/`,
  `tools/setup.sh`, `tools/export.sh`) the owner merges, or you when they say so in the chat; any
  other you merge yourself once it passes.
- **Versions are the owner's:** their button in GitHub's Actions tags a commit of `main` and CI
  releases it (README, «Проверки»), its notes the titles of the PRs merged since the last version.
- **Wishes and bugs are the repository's issues,** in Russian: first what the person in the
  headset sees or can do, then how. A big one's steps are its sub-issues. A bug or a wish found and
  not done goes into an issue of its own. An issue names the code as it is: a branch that renames
  or changes what an open issue names fixes that issue too (search the issues for the name).
- **Labels:** the section, the difficulty (просто, отладка, исследование), ошибка, скорость; each
  with its colour and meaning in `.github/labels.json`, which the Labels workflow applies on `main`
  (a new label goes there).
- **The owner's reports from the headset** come through the form «Ошибка в шлеме»
  (`.github/ISSUE_TEMPLATE/headset-bug.yml`): read its build and log first.
- **An issue you write ends with**
  «🤖 *Написал Claude (Claude Code); на GitHub показан от имени владельца.*»: GitHub shows it as
  the owner's and drops the usual footer from an issue's body. A comment gets that footer from
  GitHub itself: add nothing to it.

## Docs and numbers

- **Docs say only what the code can't, as it is now.** README and `docs/` hold what the project
  is, how to run, install and check it, and the maths; they don't retell the code. They and code
  comments describe the code as it is: no history (git and the PRs keep it), no versions. A change
  that makes a statement or a number stale fixes or removes it in the same branch.
- **Numbers** only as measured on the current code, with the tool or test that gives them. Before
  writing one, check what exactly that counter, test or tool measures and in what unit, not only
  that it prints that number.

## How to change things

- **Nothing is kept because it is there.** Look for the best way as if starting fresh and take it,
  even if it replaces what exists, up to writing the project anew; what is in the way goes out, and
  when you can't get further, try something new, ignoring what is here. Nothing is kept for
  compatibility: carry along everything that depends on a change in the same branch and migrate
  what is stored. The checks still apply.
- **Make slow frames cheaper without giving anything up,** and without counting on anything staying
  as it is now. The maths is no more fixed than the code: the wormhole's shape and metric, the
  equations of motion, light and gravity, the methods that solve them and their error budgets can
  all be revised to make frames cheaper.
- **A rule in the way:** say so to the owner and propose a replacement; don't work around it
  silently, and don't change a rule without them.
