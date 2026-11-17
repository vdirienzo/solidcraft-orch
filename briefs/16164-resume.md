# TASK 16164 — RESUME brief (the investigation is done; finish the fix)

Issue: https://github.com/tangency-labs/solidcraft/issues/16164

## What was already established (do not redo this)

A previous run of this task reproduced the user's command and established the answer to
the question the upstream triage left open:

> "Is the point you move one projected from a body or another sketch?"

**THE ANSWER IS BOTH.** The user moved a point that the sketch PROJECTS from the solid
it was drawn on. A projected point follows its source, so it cannot be moved by itself:
the refusal is CORRECT. What is wrong is the MESSAGE:

* it does not say WHICH point is the problem, and
* it does not say WHICH of the two reasons applies (fixed by the sketch, or projected
  from a body or another sketch), and
* the user sees it untranslated: the UI shows the Italian label
  "Sposta/Copia entità dello schizzo" followed by the English engine text
  "fixed or projected geometry cannot move".

## The state of the work

A previous run wrote the regression test and left it on a local branch of this same
repository:

    salvage/issue-16164b

It is one commit on top of `refs/remotes/agent/upstream-main`. It adds to
`crates/engine/src/cmd/sketch_modify_tests.rs` (the area's EXISTING test file) the test

    the_move_of_a_projected_or_fixed_point_says_which_one_it_is

which drives the user's exact command (`sketch.move` with
`{"entities": ["p8"], "translate": [6.0, 0.0], "angle": 0.0, "copy": false}`) on a
sketch whose corners are projected from an extruded solid, and expects the error to
say

    point `p8` is projected and cannot move

and, for the sketch origin,

    point `origin` is fixed and cannot move

**Your FIRST action, before anything else, is:**

    git cherry-pick salvage/issue-16164b

(If it reports a conflict, resolve it in favour of the salvage version and say so in
your report.) After that, the RED test is in front of you. Do NOT re-plan the
investigation.

There is ALSO a throwaway probe file in the repository at
`crates/engine/tests/scratch_16164.rs` (local branch `salvage/issue-16164`). It is NOT
in the commit above; it is only a probe. **It must not end up in your branch**: AGENTS.md
forbids a test file per bug. If it is in your worktree, delete it.

## What you must implement — exactly this

### 1. The engine message names the point and says which reason

File: `crates/engine/src/cmd/sketch_modify.rs`, line 3561-3565, in
`fn transform_in_place`:

    let pts = involved_points(sk, cs, ps);
    if pts.iter().any(|q| sk.points.get(*q).is_some_and(|x| x.fixed || x.link.is_some())) {
        return Err(bad(cmd, "fixed or projected geometry cannot move"));
    }

Replace that single blunt refusal with one that names the offending point and says
WHY it cannot move. The offending point is the FIRST one (in the order `pts` gives)
that is fixed or linked. The message must be of the form:

    point `<id>` is fixed and cannot move

    point `<id>` is projected and cannot move

where `<id>` is the point's ID (`sk.points.get(q).id`), `fixed` is used when
`x.fixed` is true and `projected` when `x.link.is_some()`. A point that is BOTH
fixed and projected is reported as `projected` (the projection is the reason the user
cares about; the origin is fixed and never projected).

Keep the error's shape: it must still be `bad(cmd, ...)`, so the UI keeps prefixing
"invalid parameters for `<command>`: ".

The test that the salvage commit adds expects EXACTLY these strings, including the
backticks around the id. Match it.

### 2. The message is translated

File: `crates/ui-egui/src/i18n.rs`, function `tr_engine_error` (line 443). That
function already translates the known engine errors: it strips the
"invalid parameters for `<command>`: " prefix and then matches the remaining text
against the known messages, returning `tr("sketch.error.<key>")` or
`format("sketch.error.<key>", &[("id", id)])`.

Add the handling for your new message in the same style: detect the point id and
whether the reason is "fixed" or "projected", and return the translated string.

Look at the existing helpers in that file for the shape to copy — `offset_error_id`
parses an id out of an engine message, and `format("sketch.error.offset_trim", &[("id", id)])`
builds the localized string with the id in it. Use the same pattern.

### 3. The new locale strings

The new i18n keys go into a NEW pending file:

    assets/locales/pending/sketch-move-projected-point.json

Its shape is the one of the other pending files: a map from locale code to a map of
key to text. Look at `assets/locales/pending/` for an example and copy its shape.
The keys are, for example:

    sketch.error.point_is_fixed
    sketch.error.point_is_projected

and the text has the `{id}` placeholder where the point id goes. Read
`skills/solidcraft-ui-text/SKILL.md` for the exact rules of that file (it is in this
repository) and follow them. The strings must exist for the English catalog at least,
and the file is a PENDING file: it is not merged into `assets/locales/en.json` by you.

### 4. The gate

    cargo fmt --all
    cargo test -p solidcraft-engine --lib sketch_modify

Save the passing output to `/home/user/.local/share/solidcraft-orch/logs/16164-GREEN.log`.
The failing output (before the fix) is already at
`/home/user/.local/share/solidcraft-orch/logs/16164-RED.log` — if you re-run the test
before the fix, refresh it.

If you touched `crates/ui-egui`, also run:

    cargo test -p solidcraft-ui-egui

and check the sorted lists with `cargo xtask lists`.

## Hard rules

- English code, English test names, English comments.
- No `unwrap()`/`expect()`/`panic!` in non-test code.
- Do not touch `crates/kernel`.
- The regression test stays in `crates/engine/src/cmd/sketch_modify_tests.rs`, the
  area's existing test file. Do NOT create a new test file, and do NOT keep
  `crates/engine/tests/scratch_16164.rs`.
- This does NOT change a default of the application: it changes no preference and no
  stored value, only the wording of an error message. The pull request body must
  contain exactly `Changes a default: no`.
- Do NOT push, do NOT open a pull request, do NOT merge, do NOT rebase. The harness
  publishes the branch and opens the pull request.
- Commit message:

```
Sketch: the move of a projected or fixed point says which one it is

Task: https://github.com/tangency-labs/solidcraft/issues/16164
```

- Do not run `cargo xtask ci` (90 minutes). The narrow gate above is what you run.
