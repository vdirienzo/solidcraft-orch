# Brief: capture the observable behaviour of the #9223 follow-up

You are capturing the app's own window for a pull request. Nobody is watching and you cannot ask
questions: decide yourself and report.

## The situation

- Worktree `/home/user/solidcraft-wt/issue-9223`, branch `fix-9223-cancel-undo` (head
  `9a74f297e9`). It is the follow-up to upstream issue #9223.
- The behaviour to capture: **a parameter added while the feature editor is open** (the parameter
  `len`, 20 mm), then
  - **Cancel**: the editor rolls the edit back and the design KEEPS the parameter (before the
    change, the editor refused with "the design changed while the feature editor was open; its
    current timeline was preserved" and the parameter was thrown away with the edit);
  - **Undo**: add the parameter, change `browser.visibility`, press OK, then undo the visibility
    change: the parameter (and the edit that uses it) are still there (before the change, the undo
    restored the document from before the parameter was added and the parameter vanished).
- The previous cycle already captured the **OK** path. Its driver scripts are in
  `/home/user/.local/share/solidcraft-orch/evidence/9223-feature-editor/`: `capture.py` (the driver)
  and `launch-app.sh` (how the app was started). **Read them and adapt them**; they already know
  how to build the design, open the editor, add the parameter and take the screenshots.
- The app is built from this branch, so it must be rebuilt: the engine changed.

## How to build and drive the app

The recipe is in `/home/user/Projects/solidcraft-orch/.agents/skills/solidcraft-agent-tools/SKILL.md` (29
lines; read it). In short: run it under `Xvfb :99` with `DISPLAY=:99`, talk JSON lines to the
control channel, take the screenshots with `ui.screenshot`.

- Build and target dir:
  ```bash
  cd /home/user/solidcraft-wt/issue-9223
  export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-9223
  nice -n 19 cargo build --profile ci -p solidcraft
  ```
- Around the build take the heavy token
  (`bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600`)
  and release it with `--heavy --release`. Another job may hold it: wait for it, do not build in
  parallel.
- The control channel's methods are in `docs/control-protocol.md` of the upstream checkout
  (`/home/user/Projects/solidcraft-orch`).

## What to produce

Screenshots (the app's own window, 1600 x 1000) into
`/home/user/.local/share/solidcraft-orch/evidence/9223-followup/`:

1. `cancel-01-editor-with-the-parameter.png` — the extrude's editor is open and the parameter
   `len` (20 mm) has just been added while it was open, with the editor's Distance set to the
   parameter's name.
2. `cancel-02-after-cancel.png` — after Cancel: **no error message**, the editor is closed, the
   edit is rolled back (the extrude is not built) and the design KEEPS the parameter.
3. `undo-01-after-ok-and-undo.png` — after adding the parameter, changing the visibility, pressing
   OK and undoing the visibility change: the design still holds the parameter and the extrude's
   distance is that parameter.

If you cannot produce one of them (the app refuses, a method is missing, the window does not
show it), say so in your report and produce the rest: **do not fake a capture**. A capture of the
wrong thing is worse than none.

Also write `/home/user/.local/share/solidcraft-orch/evidence/9223-followup/README.md` with one
sentence per capture saying what it shows, and the exact commands the driver ran.

## Hard rules

- Do NOT change any code of the repository, do NOT commit, do NOT push. The screenshots are the
  only thing you produce (plus the README).
- Do NOT touch any pull request, the issue, or their comments.
- Kill the app and Xvfb you started when you are done, and release the heavy token.

## Deliverable

Your final message must be one JSON object and nothing else:
{"captures": ["<the paths of the PNGs you produced>"], "missing": "<what you could not capture and
why, or empty>", "messages": "<the exact text of any error the app showed, or empty>",
 "notes": "/home/user/.local/share/solidcraft-orch/evidence/9223-followup/README.md"}
