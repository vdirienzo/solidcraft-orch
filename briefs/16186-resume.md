# TASK 16186 — RESUME brief (the first agent died on a transport reset; its RED test survives)

Issue: https://github.com/tangency-labs/solidcraft/issues/16186

## The report

Title: "surface > patch - tool not selecting any splines (3d splines)".

The recorded command context shows the Patch dialog with two inputs:
`SelInput { label: "Boundary", accept: 3 }` (PROFILES|EDGES) and
`SelInput { label: "Pass through", accept: 132 }` (VERTICES|FACES). Neither accepts a
curve, so a click on a spline finds nothing to select.

The upstream maintainer (raykholo) asked: "Which Patch field do you click the 3D
splines for, Boundary or Pass through?" The reporter has not answered.

## STATE OF THE WORK: THE RED TEST IS ALREADY WRITTEN AND COMMITTED

The previous agent worked out what a "3D spline" is in this codebase and wrote the
test. It is COMMITTED in the worktree `/home/user/solidcraft-wt/issue-16186`:

    commit 82f3bd34a9e190c9860945ece39dab6ec14072db
    crates/ui-egui/src/preselect_tests.rs | 33 +++++++++++++++++++++++++++++++++
    (message: 'wip: RED test for the patch tool and 3D splines')

WHAT THE AGENT FOUND (this is the key insight, do not re-derive it):

- A 3D sketch is made with `sketch.options` `{"sketch_3d": true}` and its lines are
  made with `sketch.line3d` `{"points": [[x,y,z], [x,y,z]]}`.
- A 3D sketch carries `profiles_3d`: the tilted square of 3D splines is ONE planar 3D
  loop (`ss.profiles_3d.len() == 1`).
- The Patch command takes such a loop as `{"sketch": sk, "profiles_3d": [index]}`.
- The test `the_patch_tool_takes_a_3d_spline` (in
  `crates/ui-egui/src/preselect_tests.rs`) builds a tilted square of four 3D lines,
  starts `surface.patch`, and asserts:

      assert!(d.inputs[0].accept & crate::selection::CURVES != 0, "the Boundary row takes a spline");

  then fills `d.inputs[0].items` with the spline and asserts the command comes out as
  `surface.patch` with `{"sketch": sk, "profiles_3d": [0]}`, and that the patch builds
  a body with one face.

THE FIX THIS TEST ASKS FOR: the "Boundary" input of the Patch dialog must accept
CURVES, and the dialog must turn a picked 3D spline into the `profiles_3d` loop it
bounds.

### What you must do

1. RUN THE TEST FIRST and save the FAILING output to
   `/home/user/.local/share/solidcraft-orch/logs/16186-RED.log`:

       cargo nextest run -p solidcraft-ui-egui -E 'test(the_patch_tool_takes_a_3d_spline)'

   If it does not COMPILE, fix the compile error first (the harness of that test
   file tells you what is available: `app_with`, `start`, `apply_commands`).

2. FIX IT. Two parts, and BOTH are needed for the test to pass:

   a. THE ACCEPT MASK. In `crates/ui-egui/src/dialogs_surface.rs` (around line 211),
      the Patch dialog builds:

          Surf::Patch { .. } => vec![
              SelInput::new("Boundary", PROFILES | EDGES, true),
              SelInput::new("Pass through", VERTICES | FACES, true),
          ],

      The "Boundary" row has to take CURVES as well. Compare with `Surf::Boundary`,
      which uses `SelInput::new("Curves", CURVES | EDGES, true)`.

   b. THE PICK -> COMMAND CONVERSION. Where the dialog's items become the command's
      parameters (the `apply_commands` of the surface dialogs, in
      `crates/ui-egui/src/dialogs_surface.rs`), a picked 3D spline must become the
      `profiles_3d` loop of its sketch, the way the engine expects it. Look at how
      the command `surface.patch` reads its references (in `crates/engine/src/cmd/`,
      the surface commands, and their schema in `crates/engine/src/schema/`). The
      existing code already handles `profiles_3d` for the patch command (the engine
      test in the agent's log ran `surface.patch` with
      `{"sketch": "S", "profiles_3d": [9]}`), so the missing piece is in the DIALOG.

3. RUN IT AGAIN and save the PASSING output to
   `/home/user/.local/share/solidcraft-orch/logs/16186-GREEN.log`. Then run the other
   tests of the file you touched, and `cargo fmt --all`.

4. IF the engine does NOT take a spline that way, do not invent a fix: report what
   you found and open NO pull request.

### Housekeeping

- The commit message of the final commit (the test and the fix TOGETHER, one commit):

      Agent: the patch tool takes a 3D spline

      Task: https://github.com/tangency-labs/solidcraft/issues/16186

  So: `git reset --soft HEAD~1` (to fold the wip commit into the final one) or amend
  it, and use the message above.

- The pull request body must contain exactly `Changes a default: no` and `Fixes #16186`.
- Do NOT push, do NOT open a pull request, do NOT merge, do NOT rebase.
- English code, English test names, English comments.
- No `unwrap()`/`expect()`/`panic!` in non-test code. Do not touch `crates/kernel`.
- The test goes in the area's EXISTING test file, never in a new per-bug file.
- Build with `CARGO_BUILD_JOBS=2` and `CARGO_INCREMENTAL=0`; the machine is shared.
- Do NOT run the full `cargo xtask ci` (90 minutes) nor the whole crate's suite: run
  only your test and the tests of the file you touched.
- Work in the order: test RED, fix, test GREEN, commit BOTH together. If you are near
  the end of your turns, commit what you have.
