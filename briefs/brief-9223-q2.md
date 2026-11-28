# Brief Q2: reproduce the reporter's scenario of #9223 on current main

You are reproducing one UI scenario and reporting what changes in the design. Nobody is watching and
you cannot ask questions.

**Do not change any file of `/home/user/solidcraft-orch` or of `/home/user/solidcraft-wt/issue-9223`,
do not commit, do not push.** If you need instrumented code, use your own scratch worktree (below).
**Write your findings to `/tmp/opencode/findings-9223-q2.md` AS YOU GO** (after every step, append
what you did and what you saw), so that nothing is lost if you run out of context. Keep the file
short and factual.

## The scenario (the reporter's, from issue #9223, by jheck7, 2026-10-30)

> "I had extruded 3 of the 10 circles, hit okay, and went back in to the extrude feature, clicked on
> the rectangular pattern which highlighted them all but did not select them, then I selected each
> one and tried to hit okay but it says the design changed while the feature editor was open."

The design: a sketch with 10 circles made as ONE circle plus a 5 x 2 **rectangular sketch pattern**.
The command the app sent when it failed was:

```json
["timeline.redefine", {"command":"solid.extrude","feature":2,"params":{"convention":"total_distance","direction":"positive","distance":"10 in","exact_regions":true,"operation":"new","profiles":[1,3,5,7,9,8,6,4,2,0],"sketch":1}}]
```

The maintainer (dudedagger42) could NOT reproduce it on 0.27.0 and wrote the key detail: **"I did
not click the sketch pattern itself"**. So clicking the pattern while the editor is open is the
suspicious step.

## What we need to know

1. Does the scenario reproduce on the CURRENT `main`? If yes: the exact steps, the exact error, and
   **what changed in the design** between the session the editor pinned and the live session when
   the guard refused.
2. If it does not reproduce: what you tried, what you got, and what is different from the
   reporter's run. A version that reproduces the refusal for another reason is also valuable.

## How to build and drive the app

The recipe is in `/home/user/Projects/solidcraft-orch/.agents/skills/solidcraft-agent-tools/SKILL.md` (read
it; it is 29 lines). In short:

- Start the app on the current `main` under a virtual display:
  ```bash
  Xvfb :99 -screen 0 1600x1000x24 &
  export DISPLAY=:99
  cd <your scratch worktree>
  CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/scratch9223 \
    nice -n 19 cargo run --profile ci -p solidcraft -- --sample --control 45999
  ```
- The first JSON line on the connection carries the token; read it from
  `~/.local/share/solidcraft/control/45999.token`, or start the app with
  `SOLIDCRAFT_CONTROL_TOKEN=$(openssl rand -hex 32)` and send that.
- Talk JSON lines to `127.0.0.1:45999`. The methods are documented in
  `docs/control-protocol.md` of the upstream checkout. The ones you will need:
  `engine.execute` (run a command), `ui.start`, `ui.click {x,y}`, `ui.screenshot {path}`, and
  whatever opens a feature's editor (search `docs/control-protocol.md` for "edit" and for
  "feature"; the previous cycle used a method named like `ui.editFeature`).
- To find what to click, take a `ui.screenshot` and READ the PNG (you can read image files).

## The scratch worktree and the build

```bash
git -C /home/user/Projects/solidcraft-orch worktree add --detach /tmp/opencode/main-9223 origin/main
```
Build there, never in the slot's target dir. Use `--profile ci` and `nice -n 19`.

Around the build take the heavy token (another job holds it right now, so expect to wait):
```bash
bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600
bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --release
```
Release it as soon as you are done building; another job needs it.

## The most valuable thing you can measure

**What changes in the design while the feature editor is open.** The guard compares the live
session with the session the editor pinned, field by field: the whole `doc` (and each part of it:
features, params, bodies, marker, links), `design_revision`, `revision`, `visibility_revision`,
`document_id`, `ids.seed()`, `active_sketch`, `active_component`, `active_occurrence_path`,
`pending_moves`, `selection`, `model`, `world_cache`.

To see them, instrument the guard in YOUR SCRATCH WORKTREE ONLY: in
`crates/engine/src/lib.rs`, in `Session::compute_editor_commands`, before the refusal, print the
fields that differ between `self` and `source` (a `eprintln!` is fine). Rebuild (the engine crate
rebuilds fast), redo the scenario, and read what it prints.

Answer, in this order of preference:
- does clicking the pattern change the **document's content**, or only the **selection** and the
  counters?
- does the editor's own **preview work** change the document or the counters?
- is the refusal caused by something the user did that is part of the edit (a selection) or by a
  real change to the design?

## Deliverable

`/tmp/opencode/findings-9223-q2.md`, short and factual:

1. reproduced: yes/no, the exact steps and the exact output;
2. the fields that differ between the pinned source and the live session when the guard refuses
   (with the instrumented output);
3. the answer to the three questions above;
4. if it did not reproduce: what you tried and what you got.

Your final message must be one JSON object and nothing else:
{"reproduced": "yes|no", "steps": "<the exact steps you ran>", "error": "<the exact error, or empty>",
 "fields_that_differ": "<the list, or empty>", "answers": "<the three answers in one line each>",
 "notes": "/tmp/opencode/findings-9223-q2.md"}
