# TASK 16460 — RESUME brief (the first agent died on a transport reset; here is what it found)

Issue: https://github.com/tangency-labs/solidcraft/issues/16460

## The report (restated, this is all the information there is)

Title: "Can't select plane to start new sketch".

"With many drawings (tabs) open, starting a new Model and a new Sketch FAILS WITHOUT
AN ERROR because a plane cannot be selected. The expected behaviour is 'Plane should
be selected'."

The command context the app recorded:

    Could not build command parameters: "Select references to build from first"
    ConstructAuto { command: "construct.plane" }
    [ SelInput { label: "ui.construct_auto.refs", accept: 33766, multi: true,
                 places: false, tip: None, items: [] } ]
    {}

`items: []` — the pick had NO candidates.

A SECOND REPORTER (JamesMowery) confirms it on 0.41.0, Debian 13 + Niri + Wayland:
"It does not fix itself until restarting. However, this issue (if related) prevents me
from selecting ANY EXISTING GEOMETRY as well." That detail matters: it is not only
the plane, it is ANY geometry, and it does not recover until the app restarts.

The upstream triage (raykholo) could NOT reproduce it on Linux and asked for a video.

## WHAT THE FIRST AGENT ALREADY DID (do not redo it)

1. It found the pick construction: the construction plane's pick is built with
   `SelInput::new("Plane", PLANES | PLANAR_FACES, false)` (the `accept` mask 33766
   of the recorded context is that combination), and `SelInput` lives in
   `crates/ui-egui/src/selection.rs` with `items: Vec::new()` and `from_face`.
2. It found where the world for the pick comes from: `crate::open_meshing::shown_world(app)`
   and `crate::open_meshing::session_world(&app.session)`.
3. It wrote TWO PROBE TESTS in the area's EXISTING test file
   `crates/ui-egui/src/viewport_plane_target_tests.rs` (that file already exists
   upstream, so it is the right place; it also already holds
   `create_sketch_picks_an_origin_plane_through_a_body` and
   `create_sketch_still_picks_a_face_beside_the_origin_planes`):

       probe_many_tabs_new_design_sketch_plane   (8 designs opened, each one
                                                  visited, then a new design, then
                                                  "sketch.create" and a click on the
                                                  XY plane -> asserts a sketch started)
       probe_many_tabs_construct_plane            (the same, then "construct.plane"
                                                  and a click -> asserts the pick
                                                  was NOT empty)

   Both PROBES PASS. So the simple shape of the bug (many tabs open, switch between
   them, new design, click the plane) does NOT reproduce with that harness.

4. It also observed that with 12 designs open on 0.41.0 on Linux, New Sketch took a
   click on the origin plane on a later tab (i.e. it works).

The probes are still UNCOMMITTED in the worktree (only
`crates/ui-egui/src/viewport_plane_target_tests.rs` is modified, +39 lines).

## What you must do — exactly this

### A. Find the actual trigger

The bug needs a condition the probes above do not create. The reporter's own words
are the best hint: the failure appears when MANY DRAWINGS ARE OPEN and it
"does not fix itself until restarting", and it also breaks picking ANY EXISTING
GEOMETRY. That points at something GLOBAL to the app, not to one tab.

Look for state that is shared by every tab and that grows with the number of open
designs, and that a pick depends on:

* the mesh/shown world: `crates/ui-egui/src/open_meshing.rs` — `shown_world` and
  `session_world`. What do they build, from which session, and what happens when
  the app has MANY sessions? Is the pick built from the ACTIVE session or from a
  stale one?
* the pick candidates for a face/plane: `crates/ui-egui/src/selection.rs` — how
  `items` is filled, and where the world it walks comes from.
* whether the tab switching (`crates/ui-egui/src/documents.rs`) updates the world
  that the pick uses, and whether a tab switch to a design with NO bodies leaves
  the app pointing at the wrong world (that would explain "cannot select ANY
  existing geometry": the pick would look at a different, empty session).
* the case where the ACTIVE design has no bodies yet (a brand new design) while
  OTHER tabs do: the reporter starts a NEW MODEL. The pick for a construction
  plane in a brand new model would have no faces, and only the origin planes are
  left. If the app then asks for a reference whose candidates are the faces of the
  OLD session, or an empty world, the pick would offer nothing.

Write the probe that reproduces the failure, in
`crates/ui-egui/src/viewport_plane_target_tests.rs` (the same file, the same
harness). The probe must FAIL before the fix and PASS after it.

### B. If you reproduce it, fix it

The fix goes where the cause is. Keep it minimal and in the area's file. The
regression test goes in `crates/ui-egui/src/viewport_plane_target_tests.rs`, in
the style of the tests already in it (no new test file).

### C. If you still cannot reproduce it, DO NOT publish

Report what you tried, what you ruled out, and what evidence would settle it (a
screen recording of the New Sketch step, the number of tabs, whether the other
tabs were edited, the Wayland compositor). A wrong fix for an unreproduced bug is
worse than no fix. In that case DELETE the two probe tests (they pass, so they are
not regression tests and they would only add noise) and leave the tree clean.

## Rules

- The two probe tests are currently named `probe_*`. If you keep them, rename them
  to what they assert; a test named "probe" is not a regression test.
- English code, English test names, English comments.
- No `unwrap()`/`expect()`/`panic!` in non-test code.
- Do not touch `crates/kernel`.
- One topic, one issue.
- This does NOT change a default of the application. The pull request body must
  contain exactly `Changes a default: no`.
- Do NOT push, do NOT open a pull request, do NOT merge, do NOT rebase. The harness
  publishes the branch and opens the pull request.
- Commit message (only if you actually fix it):

```
UI: a plane can be picked again with several drawings open

Task: https://github.com/tangency-labs/solidcraft/issues/16460
```

- The gate: `cargo fmt --all` and the nextest of `solidcraft-ui-egui` limited to the
  tests of the file you touched (`cargo nextest run -p solidcraft-ui-egui -E 'test(<name>)'`,
  or the plain `cargo test -p solidcraft-ui-egui` for that module). Save the output
  to `/home/user/.local/share/solidcraft-orch/logs/16460-GREEN.log`.
- Do not run `cargo xtask ci` (90 minutes).
