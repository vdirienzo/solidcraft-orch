# A PR can be a NO-OP: the branch it fixes may not be the branch the user runs

A green CI and a green test do NOT prove the PR fixes the reported bug. Before asking
for a label, prove that the PATH the PR changes is the PATH the user's app takes, and
that the reported symptom reproduces there.

Measured on #18192 (issue #17881, "Home frames the part in the area the panels leave
free"):

- The PR changed `refresh_layout`'s branch WITHOUT a shared panel host. The desktop
  ALWAYS takes the branch WITH the host: the selector is
  `app.universal_panel_frame().is_some()` (`crates/ui-egui/src/viewport.rs`) and the host
  is created for every app by `ensure_production` on each frame. The two functions that
  turn it off (`disable_universal_panel_host`, `disable_panel_runtime`) are only called
  from tests.
- In the branch the PR changed, the Browser was not even among the obstacles:
  `shell::occluding_rects` never reads `app.shell.browser`; the Browser's footprint
  reaches the layout only through the host. `grep browser crates/ui-egui/src/shell.rs`
  returning only the field declaration is the tell.
- The bug was ALREADY fixed in `main` by #17921, which changed `host_framing_room` to
  take the middle from `panel_obstacles` instead of the viewport. Another maintainer had
  said so in the issue ("this looks like the same bug as #17869, which draft PR #17921
  has claimed") — READ THE ISSUE before claiming a bug.

So the PR was a no-op on any real configuration, and the before/after the maintainer
asked for could not be produced FROM THAT PR.

### The check that settles it

1. Find the exact condition that picks the path your PR changes, then find the callers
   of whatever disables it. Test-only callers mean the user never sees the change.
2. Check the symptom reproduces in THAT path.
3. Measure it on the real app anyway: build the app before and after and compare the
   numbers through the control channel. Two builds of the app are ~35 min each on a
   shared box, and that is the only measurement that settles a dispute.

`bin/measure-17881-before-after.sh` is that harness: it builds two heads of the app,
drives each one over the control channel, and prints the measured position of the part
next to the free area. `bin/capture-17881-evidence.py` is the driver; it measures
`ui.worldToScreen` on the middle of the part after the camera settles and
`ui.inspect` for the viewport rectangle.

### What it measured

| build | Browser docked left, after Home | Browser hidden, after Home |
|---|---|---|
| `3f886e460^` (before #17921) | part's middle at x = 1177.8 | part's middle at x = 1177.8 |
| `3f886e460` (after #17921) | part's middle at x = 925.0 | part's middle at x = 800.0 |

The Browser card ends at x = 249, so the area the panels leave free is x = 250..1600,
whose middle is x = 925. Before the fix the part sat at 74% of the window width and did
not move when the Browser was hidden: the panels were not part of the framing area at
all. That is the shift the issue reports.

### When the PR turns out to be a no-op

Say so in the PR with the evidence, close it, and put the before/after of the commit
that DOES fix it in the ISSUE. The maintainer asked for a before/after: give him one, of
the code that works. That is what turned this PR around — the request itself produced
the measurement that proved the PR was not needed.

A no-op PR still has to be closed, not left open: an open PR holding a claim on an
issue blocks the next agent from working on it.

## Before you OFFER a commit to another author, re-read THEIR head

A commit offered to another author can go stale between the offer and the answer, and
then it is worse than useless: applied on top of their code it can LIE and BREAK things.

Measured on #18150 (issue #9178): we offered `b7b14fdd2`, a commit that renames the
fillet refusals to name the rejected curve. The author then landed the full geometry,
and on his head our commit was:

- a FALSE message: ours said "fillets work on lines and arcs", but his `takes_side`
  accepts conics and open control point splines, so the message announced a limit that
  did not exist (and the two strings are not even substrings of one another);
- a FUNCTIONAL REGRESSION: our `corner_takes` refuses conics and splines, and that
  refusal fires BEFORE his `round_freeform_corner` can round them, breaking the tests
  that prove the new geometry works;
- a CONFLICT: `git merge-tree --write-tree <their-head> <our-commit>` reported a content
  conflict in `sketch_modify.rs`.

So before publishing an offer:

```sh
git fetch origin pull/N/head:refs/tmp/up-N
git show refs/tmp/up-N:crates/engine/src/cmd/sketch_modify.rs | grep -n "work on lines"
git merge-tree --write-tree refs/tmp/up-N <our-commit>   # rc!=0 means conflict
```

Compare the strings as STRINGS, not from memory. If their implementation already covers
your contribution, RETRACT the offer explicitly with the reason — a stale offer costs the
other author real review time, and a cherry-pick that breaks their geometry costs them
their afternoon.

If a gap survives, name it precisely, with the line: here it was that their `.find()` on
`[a, b]` reports only the FIRST unusable curve, where ours joined them with " and ", and
no test of theirs covered that case. A gap with a file:line is worth an author's
attention; "there might be an issue with the a/b case" is not.
