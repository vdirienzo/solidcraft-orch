# Brief: investigate the two refusal paths of issue #9223 (no code changes)

You are investigating two refusal paths of one upstream issue before anyone changes the code.
Nobody is watching and you cannot ask questions.

**You must not change any file of the repository and must not commit or push anything.** You may
write notes to `/tmp/opencode/` and you may run the app and the CLI. If you need temporary debug
prints to see what changes in the design, put them in a scratch copy of the tree under
`/tmp/opencode/scratch-9223/` (copy the worktree, or use a `git worktree` of your own under
`/tmp/opencode/`), never in `/home/user/solidcraft-wt/issue-9223`.

## The issue

https://github.com/tangency-labs/solidcraft/issues/9223 — "EXTRUDE: operation failed".
The error the user sees is `the design changed while the feature editor was open`.

**The reporter's scenario (jheck7, 2026-10-30):** "I had extruded 3 of the 10 circles, hit okay, and
went back in to the extrude feature, clicked on the rectangular pattern which highlighted them all
but did not select them, then I selected each one and tried to hit okay but it says the design
changed while the feature editor was open." The attached settings show the command the app sent:

```json
[["timeline.redefine", {"command":"solid.extrude","feature":2,"params":{"convention":"total_distance","direction":"positive","distance":"10 in","exact_regions":true,"operation":"new","profiles":[1,3,5,7,9,8,6,4,2,0],"sketch":1}}]]
```

**The maintainer's scenario (bherbruck, 2026-11-17, ticket T-225):** "while editing an extrude, the
user added a new parameter (`Y_axis_Rod_Size_Rith`) to drive its distance, and the editor then
refused with 'the design changed while the feature editor was open; its current timeline was
preserved'. Adding a parameter for the open feature to use is part of editing it; it shouldn't count
as an outside change that throws the edit away."

**The triage (dudedagger42):** could not reproduce on 0.27.0; the same `timeline.redefine` runs fine
from the command line; in the app, opening the Extrude for editing, clicking circles in the viewport
and pressing OK worked. His boundary: "I did not click the sketch pattern itself".

## What is already fixed (do NOT redo it)

Our branch `fix-9223` (worktree `/home/user/solidcraft-wt/issue-9223`, head
`99a9d7043b7268021a858f0231e53aafb6176859`, PR #23431) already fixes ONE path: when the design only
gained parameters while the editor was open, `Session::compute_editor_commands` now accepts it
(`same_editor_context_with_gained_parameters`, `crates/engine/src/lib.rs`). That covers the OK path
of `compute_editor_commands`. The PR body says "Fixes #9223", and the repo's "Linked Issues check"
warns that the reporter's own scenario is NOT covered by it. We must decide honestly what to do.

## The two questions to answer

### Q1 — Which UI action produces which message?

Read the UI code and answer precisely, with file and line:

- `crates/ui-egui/src/dialogs.rs` (the feature editor dialog: its OK button and its Cancel/close
  button) and `crates/ui-egui/src/feature_edit.rs` (the pending edit / preview path).
- `crates/engine/src/lib.rs`: `compute_editor_commands` (message: "the design changed while the
  feature editor was open") and `restore_editor` (message: "the design changed while the feature
  editor was open; its current timeline was preserved").

Answer: when the user presses **OK** and the guard refuses, which message does the user see, and
which function raises it? Is `restore_editor` called as a fallback after a failed
`compute_editor_commands`? When the user presses **Cancel**, which message appears? Is there any
third path (preview work, `feature_edit.rs`) that produces either message? Draw the call chain.

### Q2 — What actually changes the design in the reporter's scenario?

Reproduce it and find out. Use the app's control channel (see
` .agents/skills/solidcraft-agent-tools/SKILL.md` in the upstream checkout and the `.agents/skills/` folder
in the worktree): the previous cycle drove the app with `ui.editFeature`, `engine.execute` and
`ui.screenshot` and captured PNGs into `/home/user/.local/share/solidcraft-orch/evidence/`.

The scenario to build:
1. a sketch with 10 circles (one circle plus a 5 x 2 **sketch pattern**, the reporter's "rectangular
   pattern"),
2. extrude 3 of them (the reporter extruded 3 of the 10),
3. open the extrude's editor (`ui.editFeature`),
4. **click the rectangular pattern** in the viewport — the part the triage did NOT do; this is the
   step the reporter says highlighted all the circles without selecting them,
5. select each of the circles,
6. press OK, and read the error.

Then find out what differs between the session the editor pinned (`source`) and the live session
when the guard refuses. Compare, field by field, the two sessions: `doc` (the whole document, and
then each part of it: features, params, bodies, marker, links), `design_revision`, `revision`,
`visibility_revision`, `document_id`, `ids.seed()`, `active_sketch`, `active_component`,
`active_occurrence_path`, `pending_moves`, `selection`, `model`, `world_cache`. A temporary debug
print in a scratch copy is fine; report the exact fields that differ.

Two sub-questions worth answering if the scenario reproduces:
- Does clicking the pattern change the **document** (its content) or only the **selection** and the
  revision counters?
- Does the editor's own **preview work** change the document or the counters? (Preview work runs
  while the editor is open; that is a prime suspect for a refusal caused by the editor itself.)

If the scenario does NOT reproduce on the current `main`, say so with the exact steps you ran and
what you got, and try to find what is different from the reporter's (the maintainer's triage could
not reproduce it either on 0.27.0, and did not click the pattern). A version of the scenario that
reproduces the refusal for a *different* reason is still valuable — report it.

## Where the code is

- The guard: `crates/engine/src/lib.rs`, `compute_editor_commands` (~4040), `same_document_context`
  (~4245), `restore_editor` (~4320), `same_editor_context_with_gained_parameters` (~4284),
  `design_gained_only_parameters` (~4305), `editor_base` (~4318).
- The UI: `crates/ui-egui/src/dialogs.rs` (the feature editor dialog) and
  `crates/ui-egui/src/feature_edit.rs`.
- The engine's test module for this area: `crates/engine/src/computed_commands_tests.rs` (the helper
  `extrusion_editor()` opens an editor the way the window does).

## The machine

- 12 cores, 15 GB, one heavy build at a time. Use `nice -n 19` and `--profile ci`.
- Build in a scratch target dir of your own, NOT in the slot's:
  `/home/user/.local/share/solidcraft-orch/targets/scratch9223`
- Around a big build take the heavy token
  (`bash /home/user/Projects/solidcraft-orch/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600`)
  and release it with `--heavy --release`. Another job may hold it: wait for it, do not build in
  parallel. Note that another job (the triage of a different issue) may need it too — release it as
  soon as your build is done.
- Push nothing. Never push to `origin` or to the fork.

## Deliverable

Write `/tmp/opencode/findings-9223.md` with:

1. **Q1**: the call chains, with file:line, for OK, for Cancel, and for the preview path, and which
   message each one shows.
2. **Q2**: whether the reporter's scenario reproduces on the current `main`, the exact steps and the
   exact output, and the list of the fields that differ between the pinned source and the live
   session when it refuses.
3. **A recommendation**: the smallest change that would make the reporter's scenario work (if it
   reproduces) or, if it does not, what the PR should say instead of "Fixes #9223" and why. Say
   which of these is true and what a reviewer would call correct.
4. **The tests** that a fix would need (which existing test module, which cases).

Your final message must be one JSON object and nothing else:
{"q1": "<the call chains with file:line, in short>", "q2": "<reproduced yes/no, and the fields that differ>",
 "recommendation": "<two or three sentences>", "tests": "<the test cases a fix needs>",
 "notes": "<path to your written findings>"}
