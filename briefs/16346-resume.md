# TASK 16346 — RESUME brief (the fix is already written; finish it)

Issue: https://github.com/tangency-labs/solidcraft/issues/16346

## The state of the work

A previous run of this task (the same brief) wrote the whole fix and then was killed
by the 45-minute timeout WHILE IT WAS COMPILING. The work is safe on a local branch
in this same repository:

    salvage/issue-16346

It is one commit on top of `refs/remotes/agent/upstream-main` and it contains exactly
what the brief asked for:

* `crates/ui-egui/src/viewport.rs`: `fn wake_centre` now takes the pointer position and
  the projection; a new constant `WOKEN_CENTRE_FAR: f64 = 1.2` (a fifth more than the
  circle's own radius); two new helpers, `pointer_in_sketch` (where the pointer meets
  the plane of the sketch, in the sketch's own X and Y) and `past_the_centre` (whether
  the pointer is farther from the woken centre than 1.2 x the radius of the circle or
  arc that owns it). The `None` branch of `wake_centre` (pointer over empty space) now
  sleeps the centre when the pointer went past it, and the click handler clears
  `app.viewport.woken_centre` when the click hit empty space (a deselect).
* `crates/ui-egui/tests/woken_centre.rs`: the two new tests, in the area's EXISTING test
  file — `the_centre_sleeps_when_the_pointer_leaves_the_circle` and
  `the_centre_sleeps_when_the_user_clicks_empty_space`.

**Your FIRST action, before anything else, is:**

    git cherry-pick salvage/issue-16346

(If it reports a conflict, resolve it in favour of the salvage version and say so in
your report.) After that, the implementation is in front of you. Do NOT rewrite it and
do NOT re-plan it.

## What is left for you to do — exactly this

1. Run the narrow gate and make sure it is GREEN:

       cargo fmt --all
       cargo test -p solidcraft-ui-egui --test woken_centre

   The target directory for this slot is already warm (a previous run compiled most of
   it), so this should be much faster than the first time. Let it finish; do NOT kill
   the compile and do NOT start a second one.

2. If the two new tests FAIL, fix the implementation (not the test) until they pass,
   and make sure the pre-existing tests of that file still pass — in particular
   `another_curve_puts_the_centre_back_to_sleep`, which moves the pointer from the
   circle edge to world [25,20,0] (5 mm from the centre, so it must STAY awake) and
   `hovering_a_circles_edge_makes_its_centre_easy_to_take`.

3. Run the whole test file, not only the two new tests:

       cargo test -p solidcraft-ui-egui --test woken_centre

   Save the output to `/home/user/.local/share/solidcraft-orch/logs/16346-GREEN.log`.
   If you had to change anything to make the tests fail before the fix, save that
   failing output to `/home/user/.local/share/solidcraft-orch/logs/16346-RED.log`.

4. Check the whole crate's tests if the narrow gate is fast enough:
   `cargo test -p solidcraft-ui-egui`. If it takes too long, skip it and say so.

5. Commit. The salvage commit is already a commit; make sure the final state of the
   branch is ONE commit on top of `refs/remotes/agent/upstream-main` with this exact
   message:

```
Sketch: the arc centre sleeps again when the pointer leaves it

Task: https://github.com/tangency-labs/solidcraft/issues/16346
```

   (If the cherry-pick produced two commits, squash them into one with
   `git reset --soft refs/remotes/agent/upstream-main && git commit`.)

## Hard rules

- English code, English test names, English comments.
- No `unwrap()`/`expect()`/`panic!` in non-test code (the test file may use them).
- Do not touch `crates/kernel`.
- The regression test stays in `crates/ui-egui/tests/woken_centre.rs`, the area's
  existing test file. Do NOT create a new test file.
- This does NOT change a default of the application: it changes no preference and no
  stored value, only the lifetime rule of a highlight inside the sketch viewport. The
  pull request body must contain exactly `Changes a default: no`.
- Do NOT push, do NOT open a pull request, do NOT merge, do NOT rebase. The harness
  publishes the branch and opens the pull request.
- Do not run `cargo xtask ci` (90 minutes). The narrow gate above is what you run.
