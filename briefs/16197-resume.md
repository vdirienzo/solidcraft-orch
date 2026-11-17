# TASK 16197 — RESUME brief (the first agent ran out of turns while mapping the code)

Issue: https://github.com/tangency-labs/solidcraft/issues/16197

## The report (translated from French)

Title: "How to prevent the colouring of a closed zone in a sketch?"

"When a set of lines defines the edge of a closed zone, it gets a pale orange colour.
That is handy if you want to build an extrusion from that sketch later; it should be
possible to enable that by clicking on a button somewhere.

But if you click INSIDE a closed zone that is in ANOTHER sketch, while you are in
sketch mode, that zone gets coloured DARK BLUE, and you can no longer see it.

This part of the interface needs to be reworked completely."

Steps to reproduce: "click in a closed zone, when you are in sketch mode".
Version 0.40.1, Windows 10. No screenshot, no recording, no comment on the issue.

## WHAT THE FIRST AGENT ALREADY MAPPED (do not redo it)

The first agent ran out of turns after 3 minutes. It established that the code
involved is in these files:

* `crates/ui-egui/src/view_pick.rs` — the pick.
* `crates/ui-egui/src/select_other.rs` — `note_click(app, p, if add { None } else { sel })`
  is called from the viewport (around line 6105 of `viewport.rs`) when a click
  happens. This is where a click in the viewport is turned into a selection.
* `crates/ui-egui/src/viewport.rs` — the viewport and its click handling.
* `crates/ui-egui/src/viewport_overlays_tests.rs` — the existing tests of the
  overlay that DRAWS the sketch profiles (it holds
  `an_open_extrude_keeps_its_taper_limits_while_the_profiles_stay`).
* `crates/ui-egui/src/view_pick_tests.rs` — the existing tests of the pick.
* `crates/ui-egui/src/select_other_tests.rs` — the existing tests of the click
  handling (it holds `long_press_picks_hidden_profiles_behind_a_body_without_revealing_them`
  and `approximate_long_click_reaches_profiles_and_shows_all_eight_rows`).
* `crates/ui-egui/src/sketch_display_ui_tests.rs` — the existing tests of the sketch
  display.
* `crates/ui-egui/src/documents.rs` — the per-tab sessions (the agent was reading
  around line 1270 and 1507; line 1507 says "A tab switch brings in the other
  design's own Render selection", which is the kind of per-tab state that matters
  here).
* `crates/ui-egui/src/open_meshing.rs` — `shown_world(app)` and
  `session_world(&app.session)`.

The worktree is CLEAN: no commit, no modified file.

## What you must do — exactly this

### 1. Answer the question the code gives you

The defect has two halves and you only need ONE of them to be a real bug:

**(a) THE WRONG DESIGN IS PAINTED.** In sketch mode, a click inside a closed zone
paints the zone of a DIFFERENT open design. The question: when the viewport picks
in sketch mode, does it iterate over the profiles of EVERY open design (the
sessions of all the tabs) instead of only the ACTIVE one? Read `select_other.rs`
and `view_pick.rs` and find where the profiles that can be picked come from. If it
walks all the sessions, that is the bug.

**(b) THE WRONG COLOUR.** Even for the ACTIVE design, a click inside a closed zone
paints it DARK BLUE instead of the pale orange of a usable profile, and it becomes
unreadable. Find the code that chooses that colour and the tokens of the theme
(`crates/theme/`) for the two colours.

The report says both happen ("this part of the interface needs to be reworked
completely"), and the reporter does not say whether the dark blue zone belongs to
the other design or to the active one. Decide which of (a) and (b) is real, from
the code, and fix that one. If BOTH are real, fix them in ONE commit: they are one
topic (the click in sketch mode repaints a closed zone wrongly).

### 2. Reproduce it headless, in the EXISTING test file

The regression test goes in the existing test file of the area — `select_other_tests.rs`
if the defect is in the click handling, `view_pick_tests.rs` if it is in the pick,
`viewport_overlays_tests.rs` if it is in the drawing. Do NOT create a new test file.

The test must: open TWO designs (the harness of those test files already knows how
to open more than one — look at how their existing tests do it), put a closed
profile in the FIRST one, enter sketch mode in the SECOND one, click inside the
closed zone of the FIRST one, and assert that the zone of the first design was NOT
repainted (and, for (b), that the zone kept the pale orange colour).

The test must FAIL before the fix and PASS after it.

### 3. If you cannot reproduce it, DO NOT publish

The report has no screenshot and no recording, so the exact interaction is
ambiguous. If your reading of the report cannot be reproduced, report what you
tested and what you ruled out, and open NO pull request. A wrong fix for an
unreproduced bug is worse than no fix.

## Rules

- English code, English test names, English comments.
- No `unwrap()`/`expect()`/`panic!` in non-test code.
- Do not touch `crates/kernel`.
- A regression test goes in the area's EXISTING test file, never in a new per-bug
  file.
- One topic, one issue.
- This does NOT change a default of the application. The pull request body must
  contain exactly `Changes a default: no`.
- Do NOT push, do NOT open a pull request, do NOT merge, do NOT rebase. The harness
  publishes the branch and opens the pull request.
- Commit message (only if you actually fix it):

```
UI: a click in sketch mode does not repaint the profile of another design

Task: https://github.com/tangency-labs/solidcraft/issues/16197
```

- The gate: `cargo fmt --all` and the nextest of `solidcraft-ui-egui` limited to the
  tests of the file you touched (`cargo nextest run -p solidcraft-ui-egui -E 'test(<name>)'`).
  Save the output to `/home/user/.local/share/solidcraft-orch/logs/16197-GREEN.log`.
- Do not run `cargo xtask ci` (90 minutes).
- Do not spend the whole budget mapping the code: pick the reading of the report
  that you can test, write the test, and finish. If you are running out of turns,
  commit the test and the fix together and stop.
