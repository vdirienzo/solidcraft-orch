# Checking a rule against the numbers the code really sees

Use this when a delegated PR implements a THRESHOLD, a SNAP RULE, a CLAMP or any other rule
whose correctness depends on constants that live in a fixture, a camera or a config. The gate
tells you the change broke nothing; this tells you the rule is RIGHT.

The method: get the real constants, then evaluate the rule over every case it must satisfy.

## Step 1 — get the constants from the code, not from the brief
Find where the value the rule divides by comes from and compute it by hand. A UI rule that
keys off a grid step usually reaches it like this:

    camera distance and field of view  ->  half_height
    half_height                        ->  grid_step (a power-of-ten snapped value)
    grid_step                          ->  the coarse and fine steps the rule uses

Read the harness/camera defaults in the repo and write the derived numbers down in the PR body.
A number in a PR body that the reviewer cannot reproduce is a claim, not a justification.

## Step 2 — write the rule as a function, in a scratch script
Not as prose, as code. The rule is a formula; evaluating it is mechanical.

    def lattice(v, fine):  return round(v / fine) * fine
    def crossing(v, coarse): return round(v / coarse) * coarse

    def takes_crossing(v, coarse, fine):
        c, l = crossing(v, coarse), lattice(v, fine)
        d, ll = abs(c - v), abs(l - v)
        eps = fine * 1e-6
        if ll <= eps and d > eps: return l     # an exact lattice value must not be dragged
        if d <= fine:            return c     # within one fine step of the crossing
        if ll > fine/4 and d <= coarse/4: return c
        return l

Order of the clauses is part of the rule. A threshold checked before the "the user placed this
value deliberately" clause silently overrides it — that ordering bug is invisible to a green
gate and to a unit test written alongside the implementation.

## Step 3 — enumerate the cases and check every one
The case list comes from two places and BOTH are mandatory:
- what the issue asks for (usually a new test's expected outcome);
- the existing tests that constrain the behaviour (a scenario that pins a coordinate, a
  threshold a sibling test leans on).

Run them all in one script and print a table with the verdict per case:

    cases = [("issue test", 20.3125, 20.0), ("pinned scenario", 14.0, 14.0), ...]
    for name, v, expected in cases:
        got = rule(v, coarse, fine)
        print(f"{name:22} v={v:<9} -> {got:<9} {'OK' if got == expected else 'FALLA'}")

Also try the EDGE cases the case list does not cover: the exact value, the value one step
either side, and the same values at a DIFFERENT scale (the coarse step is usually not a
constant — a view zoomed out changes it, and a rule that only works at one scale is broken at
the other).

## Step 4 — re-check your own expectations before they reach an agent
The expectations you write are also guesses until they are checked. If a synthetic expectation
disagrees with the issue's own test, the synthetic expectation is the wrong one: recompute the
geometry and see which side of the scale the case sits on (a point half a cell from the
crossing is FAR when the cell is small, and NEAR when the cell is large).

When your own rule turns out wrong after you already sent it, correct it in the open — name
the failing case, give the numbers, and say what the rule must produce. An agent cannot debug a
specification that reads as authoritative and is wrong.

## Step 5 — make the test the specification
The rule's unit test must contain the concrete cases WITH their numbers, and it must FAIL
against the old rule. A test written to match the implementation agrees with it by
construction and proves nothing.
