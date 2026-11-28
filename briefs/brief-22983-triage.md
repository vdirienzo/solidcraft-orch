# Brief: triage issue #22983 and claim it (no code changes yet)

You are triaging one upstream issue before anyone changes the code. Nobody is watching and you
cannot ask questions.

**You must not change any file of the repository and must not commit any code.** You MAY write
notes to `/tmp/opencode/`. The one thing you DO publish is the claim (an empty commit and a draft
pull request), because that is how the issue becomes ours and the rule of upstream is that the
claim comes first.

## The issue

https://github.com/tangency-labs/solidcraft/issues/22983 — "Command line pictures of metallic
parts: `render` with no saved setup draws them nearly black, and `snapshot` ignores pbr".

Labels: `area:render`, `needs-triage`. Filed 2026-11-28, no pull request, not fixed upstream.

**The symptom, as the reporter gives it:**
- `snapshot` with and without `pbr` writes **byte-identical files**: both are
  `992a0d83189677bda36b60afd51deb5a50d8725ce36fc6e44602ff281df572a2`.
- `render` with `pbr` gives `#010000` on the top face and `#0e0f11` / `#18191b` on the sides, where
  the same part without `pbr` gives `#c5764d` / `#82878e` / `#7f848a`.

**The repro** (the issue attaches the files): a 40 × 30 × 6 mm plate with two `appearance.assign`
calls that carry a `pbr` block, then

```
solidcraft-cli snapshot plate.json --out snapshot-plate.png --width 960 --height 600 --no-grid --no-axes
sha256sum snapshot-plate.png
```

and the same with the variant that has no `pbr` block. Both hashes come out equal.

## Where the cause is (a scout's reading of `origin/main`, verify it, do not trust it)

- The CLI picture path is `crates/engine/src/cmd/render.rs` and `crates/render`. Neither reads the
  appearance's PBR block: the PBR parameters live in `crates/doc/src/pbr_appearance.rs`, and the
  PBR preview itself is only in the GUI path (`crates/ui-egui/src/viewport.rs`).
- The default lighting of `render` with no saved setup is the three fixed neutral directional
  lights of `docs/render-opaque-pbr.md` — no environment.

## The two questions to answer

### Q1 — Does the symptom still reproduce on current `main`?

Build the CLI (headless, no window) and run the exact commands of the issue with the two designs.
Report the two hashes and the pixels you measured (the hex colours of the top face and the sides
in each picture). If the two pictures come out identical, the bug is there. If they differ, the
symptom no longer reproduces and the issue must be closed as fixed — say so and stop.

**This box is small** (12 cores, 15 GB). Use `--profile ci`, `nice -n 19` and a target dir of your
own under `/home/user/.local/share/solidcraft-orch/targets/`. Take the heavy-build token around
the build:

```
bash ~/.local/share/solidcraft-orch/bin/slot-lock.sh --heavy --take --wait 3600 --owner triage-22983
bash ~/.local/share/solidcraft-orch/bin/slot-lock.sh --heavy --release
```

Do NOT build the whole workspace by hand. If the CLI is too heavy for this box, say so in the
verdict and stop there: a measurement you could not take is worth more than a guess.

### Q2 — Which half of the issue is a bug and which half is a decision?

The issue carries two things:
1. **`snapshot` ignores `pbr`.** The picture does not change when the appearance changes. That is
   a plain bug in the app layer with a testable rule: *the picture must change when the appearance
   changes*.
2. **`render` with no saved setup draws metal nearly black.** That asks for environment lighting
   with no setup: it is a product decision, not a fix, and the issue itself suggests a new option
   (a `snapshot` option that shades PBR with environment light), which is a feature request.

Before deciding, check what upstream thinks:
- `gh issue view 22983 --repo tangency-labs/solidcraft --comments` does NOT work on this repo
  (the GraphQL "Projects (classic)" error): use
  `gh api repos/tangency-labs/solidcraft/issues/22983/comments` and
  `gh api repos/tangency-labs/solidcraft/issues/22983` instead.
- Look for a label like `in progress`, `needs-triage` still on it, or a comment from a maintainer
  that says what the scope is.
- `git log origin/main --grep=22983` and `git log origin/main --grep="pbr"` to see whether
  something landed already.

**Say in your notes which half you would take and why**, with the evidence. The default answer is
the first half (a bug), and the second half is out of scope unless a maintainer asked for it.

## Then claim it (only if Q1 says the symptom is still there)

Upstream's rule: the claim is a **draft pull request**, and the issue number goes in the **title**
of the draft, because the claim bot reads it there.

```
cd /home/user/Projects/solidcraft-orch            # the checkout of upstream, level with origin/main
git fetch origin
git switch -c fix-22983 origin/main
git commit --allow-empty -m "claim: #22983"
git push fork HEAD:fix-22983
gh pr create --repo tangency-labs/solidcraft --draft --base main --head vdirienzo:fix-22983 \
  --title "Render: a command line picture now shows the metallic appearance (#22983)" \
  --body "Fixes #22983

Changes a default: no

The claim of this issue. The fix comes next."
```

Then run the claim check:

```
bash ~/.local/share/solidcraft-orch/bin/claim-verify.sh 22983 --our-pr <the number it printed>
```

Exit 0 means the claim is ours. Exit 1 means we lost it: **close your draft** and stop with
verdict `blocked`. Exit 2 means it could not be checked: stop with verdict `blocked`.

**Never** push to `origin` (that is upstream, read-only). Push only to `fork` (vdirienzo).
**Never** ask for `approved-for-ci` or `ready to merge`, and never merge.

## The body of the draft

`Fixes #22983` (a closing keyword; `Refs` does not close) and the line `Changes a default: no`.
Nothing else is needed in a claim.

## Your last message

One JSON object and nothing else:

```json
{"verdict": "claimed|blocked|fixed|not-reproducible", "pr": 0, "head": "<sha>",
 "symptom": "<what you measured: the two hashes, the pixels, the exact commands>",
 "scope": "<which half of the issue and why, with the evidence>",
 "cause": "<file and line of the cause, if you found it>",
 "blocked": "<what blocks it, or empty>"}
```

Write the same content, with more detail, to `/tmp/opencode/findings-22983.md` — your last message
can be cut short, that file cannot.
