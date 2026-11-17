# Issue #17604: not reproducible on current main (no PR)

**Verdict: the bug described in the issue does not reproduce on `origin/main` (0.43.0), so no
pull request was opened.** This is a faithful "cannot reproduce", with the evidence.

## The report

- Title: "CREATE SKETCH: operation failed" (area:sketch, bug, needs-triage).
- Actual behaviour: "can not create sketch on a face of a object created as a mirrored extrusion".
- Reproduction: "create an object by extruding something, then create a mirror of the part and try
  to create a sketch on its surface".
- Expected: "new sketch beeing created on a surface of a body".
- Error shown by the user: "Utwórz szkic: this face can't keep an attachment: its history can't
  tell it apart from other faces (an edit reshaped it, or more than one face could claim its
  name). Pick another face, or use a fixed plane here (fixed:true), which won't follow later
  changes to the face".
- Reported on 0.42.0 (1b1e940c), Windows 11, NVIDIA RTX 4060.
- The screenshot of the issue shows an ASSEMBLY (`podstawka:1` holding `Bryła3/4/5` and
  `Szkic6..13`), and the dialog reports `Body5 · face 14` with the error text above.

The error string is produced in `crates/engine/src/cmd/sketch_face.rs` (around line 220).

## What the maintainer already tried

ancientastronauttheorist commented on the issue (2026-11-16) that he tried to reproduce it on
0.42.0 AND on current `main` by extruding a 30 x 20 x 10 mm box and mirroring it every way he
could think of (as a body and as a feature; as a separate copy and joined to the original with
Combine; about the YZ plane with and without a gap; about the box's own end face): **in all 42
cases Create Sketch attached to every face of the mirrored copy**. He asks for the user's design
file to reproduce it.

## What we measured

Two attempts. The first one (a loop agent) died on a provider transport error and left a RED
test uncommitted; it was rescued to the fork branch `wip/issue-17604` (08bf1e377). The second
attempt drove the scenario directly with a probe that mirrors the extrusion FEATURE BY ITS REAL
NAME (the first attempt's probe never executed that path: it asked for a feature named
"Extrude1" while the feature is named after the extrusion, e.g. "Block").

The probe (`probe_17604_scenarios` in `crates/engine/src/cmd/sketch_face_tests.rs`, output in
`logs/17604-probe4.log`) tried every planar face of every body of seven arrangements and printed
both the doc-level capture result and the engine-level `sketch.create` result:

| # | Arrangement | Result |
|---|---|---|
| S1 | feature mirror (`features:["Ex"]`, plane X), seed + copy | all faces `exact_face` |
| S2 | feature mirror with a gap (plane at x=30) | all faces `exact_face` |
| S3 | feature mirror about XY | all faces `exact_face` |
| S4 | joined feature mirror (boss on base), 17 faces | all faces `exact_face` |
| S5 | mirror of a mirror (`features:["Mirror1"]`) | all faces `exact_face` |
| S6 | body mirror | all faces `exact_face` |
| S7 | feature mirror plus a parameter change (d1 -> 20 mm) | all faces `exact_face` |

No RED: no arrangement refused an attachment.

## Why it attaches (the mechanism)

A copied face carries the `@F<n>.<instance>` suffix (for example `F2:top@F3.1`), and the
lineage/certificate fallback in `crates/doc/src/{face_anchor.rs, config_certificates.rs,
history_names.rs, naming.rs, persistent_name.rs, eval.rs, lineage.rs}` resolves it: the internal
capture returns `certified=true` and the engine returns `attachment="exact_face"`.

## What would be needed to go further

The user's own design file (a `.solidcraft` file with the assembly above) is what the maintainer
asked for. Without it, the failing arrangement is unknown: the issue's assembly has components,
more than one body, and sketches that are not in the simple box case. The next step is to ask the
reporter for the design file, not to guess a fix.

## Leftovers

- The probe was reverted: the worktree `/home/user/solidcraft-wt/issue-17604` is clean at
  651c465e0, and the probe history is on the fork branches `wip/issue-17604` (08bf1e377) and
  `wip/issue-17604-probe` (9da2ab11f).
- No pull request was opened, nothing was published against this issue.
