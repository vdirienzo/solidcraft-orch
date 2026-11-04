# Issue #10750 — "Box dimensions are swapped?" — the dimensions are NOT swapped

**Verdict: the bug does not reproduce. No PR was opened.**

The reporter's screenshot shows a design with the **Y-up** preference on. With Y up,
the world Y axis stands vertically on screen, and the Box's Width is the world Y size.
So the Width is what appears to be the box's vertical dimension, and the Height
(world Z) recedes toward the front. The box is built correctly.

## 1. Where the mapping lives

Every layer maps the same way, Length → X, Width → Y, Height → Z:

| Layer | File:line | Mapping |
|---|---|---|
| Engine command | `crates/engine/src/cmd/features.rs:1386` | `(l, w, h) = (length, width, height)` |
| Engine command (stored) | `crates/engine/src/cmd/features.rs:1410` | `FeatureKind::Box { length: l, width: w, height: h }` |
| Model evaluation | `crates/doc/src/eval.rs:5946` and `:7848` | `Vec3::new(val(length), val(width), val(height))` → X, Y, Z |
| Kernel | `crates/kernel/src/build.rs:518` | `box_solid(a, b)` → `s = hi - lo` per axis |
| Dialog field labels | `crates/ui-egui/src/dialogs_dense.rs:615-620` | `length`→`ui.length`, `width`→`ui.width`, `height`→`ui.height` |
| Click-to-place corner | `crates/ui-egui/src/dialogs.rs:5084` | `coord(p.x, size("length"), Vec3::X)`, `coord(p.y, size("width"), Vec3::Y)`, `coord(p.z, size("height"), Vec3::Z)` |

## 2. The test (RED that is not RED → the bug does not reproduce)

Added to the area's EXISTING test file (no new file per bug):
`crates/ui-egui/src/primitive_units_tests.rs` →
`the_box_dialog_makes_the_width_the_side_and_not_the_height`

It types Length 10, Width 20, Height 30 into the Box dialog, presses OK and
measures the body. A non-cubic box is required: a cube cannot show a permutation.

**Result on UNMODIFIED code — PASSES (the bug does not reproduce):**

```
test primitive_units_tests::the_box_dialog_makes_the_width_the_side_and_not_the_height ... ok
test result: ok. 19 passed; 0 failed; 0 ignored; 0 measured; 3914 filtered out; finished in 45.93s
```

The params the dialog sends are the typed ones and the body measures as written:
`sent` → `{"length":"10","width":"20","height":"30"}`; body bbox `[10.0, 20.0, 30.0]`.

### The test has teeth (swap introduced on purpose → RED)

Temporarily swapping width and height in `crates/doc/src/eval.rs` (both sites,
5946 and 7848), the same test fails with the permutation visible:

```
thread 'primitive_units_tests::the_box_dialog_makes_the_width_the_side_and_not_the_height' panicked at crates/ui-egui/src/primitive_units_tests.rs:82:5:
[10.0, 30.0, 20.0], want [10.0, 20.0, 30.0]
test result: FAILED. 0 passed; 1 failed
```

`crates/doc/src/eval.rs` was restored to HEAD afterwards (`git diff --quiet` clean).
The test therefore fails on a real swap and passes on the real code.

## 3. The screenshot, measured

From the image attached to the issue
(`https://github.com/user-attachments/assets/dc0d3240-f4fa-4224-bfd7-3c0a36d988ce`):

- The nav gizmo shows **Y at the top** (green Y up, X lower-right, Z lower-left)
  → the design has the **Y-up** preference on.
- The dialog reads **Length 1 mm, Width 0.5 mm, Height 1 mm** (the Width field is
  focused and shows `.5`; it is 0.5, not 5).
- The rendered solid: top face 603 × 348 px; vertical (screen-vertical) edges 175 px.

Solving the iso view (`yaw = -π/4`, `pitch = 0.6154797086703874`, up = Y):

- top face vertical/horizontal = 348/603 = **0.5771**, vs the iso prediction
  0.4082/0.7071 = **0.5773** → the view is the iso view, confirmed.
- scale = 603 / (0.7071 × (Lx + Lz)) = 603 / (0.7071 × 2) = 426.4 px/mm.
- world Y extent = 175 / (0.8165 × 426.4) = **0.503 mm** → the vertical dimension
  is the **Width (0.5 mm)**, exactly as typed.

Under a width↔height swap the vertical edges would be 348 px and the two slants
would differ by 2×. Measured: verticals 175 px, slants equal (~348–370 px).
**The swap is excluded by the pixels.**

## 4. Upstream's own coverage and answer

- `origin/main:crates/ui-egui/src/primitive_units_tests.rs:238` already asserts
  `assert_size(&mut h.app.session, [40.0, 30.0, 20.0])` for a box with
  length 40, width 30, height 20 — the same mapping, already pinned upstream.
- The issue's comment (austin62jake, 28 merged commits) reproduces it on 0.29.0
  (`main` at `bc4d35b0`, confirmed an ancestor of `origin/main`) and explains the
  cause: *"The view cube in it has Y pointing up, so this design is shown with Y up
  ... Box always makes its sizes along the design's axes ... With Y up, Width is the
  box's vertical size, and Height runs toward the front."*
- They note that making Box's Height follow the up preference *"is a decision for
  the maintainers"*, and that a Box feature stores its sizes as X, Y and Z, so the
  same design would also have to read right under the other preference.

`assets/locales/en.json:5035` (`ui.up_axis_note`) documents the preference as
view-only: *"Which axis points up in the views (axis view, Home, Look At).
Designs are unchanged."*

## 5. Why no PR

The issue is still OPEN with `needs-triage` and no maintainer decision; the
commenter explicitly reserves the behaviour change for the maintainers, and
`RULES.md` lists *"anything that changes default behaviour"* as not worth an
agent right now. The geometry is already correct and already covered by an
upstream test, so there is no defect to fix and no non-cubic permutation to
correct.

The regression test is committed locally on
`fix/issue-10750-box-dimensions` (commit `76c2a2796`) so the invariant stays
pinned; it was not pushed and no PR was opened.

## 6. Commands and numbers

```
# RED test on unmodified code (GREEN — bug does not reproduce)
cargo test --profile ci -p solidcraft-ui-egui --lib primitive_units_tests
  → 19 passed; 0 failed

# teeth: swap width/height in crates/doc/src/eval.rs → RED
  → [10.0, 30.0, 20.0], want [10.0, 20.0, 30.0]  (1 failed)
  (eval.rs restored to HEAD afterwards)

# clippy
cargo clippy --profile ci -p solidcraft-ui-egui --lib --tests -- -D warnings → EXIT=0

# claim check
bash bin/claim-verify.sh 10750 → VEREDICTO=OK el issue esta libre (nadie lo menciona)

# gate
bash bin/gate.sh 10750 76c2a2796 → see the gate log
```
