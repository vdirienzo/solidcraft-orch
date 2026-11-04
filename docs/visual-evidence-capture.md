# Capturing visual evidence on a headless box

A PR for an observable CAD/UI change needs real evidence (a screenshot or a recording the
orchestrator captured). The app can be driven headlessly; the pieces already exist and
reusing them saves an afternoon.

## Tell the agent the environment is PREPARED, or it will report it impossible
An agent that is not told will look for a display, find none, and write in its report that
screenshotting is impossible here — on a box where a headless X server is already running and
the software Vulkan stack is installed, and where the orchestrator has already captured
evidence the same way. The agent is not wrong about what it found; it is wrong about what
exists.

So the brief for an evidence task names the environment, and says that it is already set up:
"the headless graphics environment is prepared on this box: the X servers, the client X
libraries and lavapipe as the Vulkan ICD. Build the app ONCE, in the slot's own target dir,
and reuse that binary."

An agent that cannot get a picture anyway can still ship MEASURED state: the design state
before and after, published on a fork `evidence/<issue>-<slug>/` branch and linked from the
body, with the body saying plainly that it is state and not a picture. The repo's own
convention for the pictures is a fork branch of that shape, so a state dump on the same branch
is the honest substitute — but say what it is, because a reader who expected a picture will
judge the link otherwise.

## Driving the app headlessly
- The app takes `--control <port>`; the token is read from `SOLIDCRAFT_CONTROL_TOKEN` (a hex
  string) and must be THE SAME in the app and in the script.
- The control channel is TCP with one JSON per line. THE FIRST LINE MUST CARRY THE TOKEN
  (`{"method":..., "params":..., "token":"..."}`); later lines on the same connection do not.
  Without it every request is refused.
- `ui.screenshot` saves the WINDOW WITH THE egui overlay — which is where the dialogs and
  their messages are drawn. `ui.render` only draws the 3D scene and misses all of it, so it
  cannot photograph a dialog, a status chip or a message.
- World -> screen is `ui.sketchToScreen {"points":[[x,y]]}`; `ui.at` is for named things.
  `ui.move`/`ui.click` take SCREEN coordinates, not world ones.
- There is no GPU: the adapter is `Vulkan · llvmpipe` (lavapipe) and the app opens a real
  window.

## THE gotcha: use a display of YOUR OWN
On a display where other apps are running and there is NO window manager, X reports the
window as fully covered, so egui SKIPS the UI pass. The symptoms are `ui.screenshot`
answering *"no frame was presented (window hidden?)"* and a click that never reaches the
button. Nothing in the app is broken and nothing in the script is wrong: the window is simply
never shown.

The fix is to start your OWN X server on a FREE display and use that one. The box has several
displays (all 1600x1000x24) but the popular ones already carry other apps, so they are not
usable — pick a free one and start a server on it.

## The shared client: do not write a seventh copy
The capture scripts used to be six copies of the same class (one per capture). The shared
module is `bin/sc_control.py` in the orchestrator:

    import sys
    sys.path.insert(0, "/home/user/.local/share/solidcraft-orch/bin")
    from sc_control import connect

It offers `connect`, `execute`, `inspect`, `handles`, `screenshot`, `pump` and `fresh_doc`.
Its `screenshot(c, path)` wrapper detects the hidden-window case above and says what to do
about it instead of relaying "no frame was presented" — use that wrapper, not the raw method.

## One pointer event per frame: a click with no pointer under it does nothing
`synthetic_input()` drains ONE pointer event per frame. A click queued right after a move
arrives with no pointer under it: `viewport.hover` stays null, nothing is picked, and the
capture shows no point. Pump frames between the move and the click (`ui.inspect` plus a
sleep, repeated) and the click lands. The symptom is deceptive: every request returns
`ok: true`, the tool activates, the status says "Click in the sketch", and the picture still
has no point — so a script that only checks for errors will happily write two byte-identical
PNGs and call it evidence.

## The BEFORE state does not need a second build
A full build of the app is tens of GB and the disk is shared. To photograph the state before
the fix, revert ONLY the hunk of the fix in the worktree and rebuild INCREMENTALLY in the
same `CARGO_TARGET_DIR` (minutes, no extra gigabytes); then re-apply the fix and rebuild
again — the binary comes out byte-identical, which is worth checking (compare the sha256 of
the two binaries): it proves the two pictures differ only because of the hunk.

## Prove the evidence shows what it claims
Do not accept "the capture script did not error". Check the PICTURE and the MODEL:
- download the published PNG and LOOK at it (the app's own coordinate readout beside the point
  is the evidence: `20.00 mm, 20.00 mm` on a crossing vs `15.00 mm, 15.00 mm` between lines);
- read the model back (`engine.execute sketch.inspect`) and confirm the point's `at` is
  exactly the coordinates the issue asks for;
- or project the drawn grid lines with the app's own `ui.sketchToScreen` and measure the
  distance from the marker to each line.
A capture of the wrong thing (a point that never landed, a camera too far to see the grid) is
indistinguishable from a good one if you only check the bytes.

For a change whose whole point is a STRING (a message, a label, a unit), publish the
verbatim text next to the picture: the raw text of the value, the engine's error and the app's
message, each as its own file. A picture cannot show a trailing space, and a trailing space is
often the whole bug — the text file settles what the image cannot.

The BEFORE and the AFTER must show the SAME design, in the same view, so the only difference
between the two pictures is the change under test.

## The evidence branch: a slash in the branch name breaks the raw URL
The convention is a fork branch `evidence/<issue>-<slug>/` with the pictures in it, linked
from the body as `raw.githubusercontent.com/<owner>/<repo>/<branch>/<file>`. That URL does NOT
resolve when the branch name itself contains a slash: the server cannot tell the branch from
the path. Two workarounds, both fine:
- create the branch WITHOUT a slash (`evidence-<issue>-<slug>`), or
- keep the slash and ALSO copy the files to the ROOT of the branch, so the flat URL works.
Either way, verify the URL returns 200 with an image content type BEFORE it goes into the
body — a broken image link in a PR body is invisible to every checker and to the reviewer.

## The grid step follows the camera zoom
The drawn grid's spacing is derived from the camera (`grid_step(half_height)`, and the
half-height comes from the camera distance and field of view), so the same world coordinate
is a crossing at one zoom and a mid-lattice point at another. For an evidence picture, set
the camera so the crossing is a visible crossing AND the "exact lattice" case sits BETWEEN
two drawn lines — otherwise the two pictures show the same thing and prove nothing.

## The environment of THIS box, and the traps that cost an afternoon
These are the details of the box the orchestrator runs on; check them against the repo before
relying on them elsewhere, because they change.

- The control channel's DEFAULT port is the one in the code (`crates/engine/src/control_auth.rs`),
  NOT a port picked by hand in a reference script: if the port is taken, the next one is
  tried. Pass `--control PORT` to the app.
- The token can be FIXED with `SOLIDCRAFT_CONTROL_TOKEN` (a hex string), so the script and
  the app agree without reading the app's token file.
- There are several Xvfb displays (all 1600x1000x24), but the popular ones carry other apps,
  so they are NOT usable: check which display is free (`/tmp/.X11-unix/`) and start your own
  server on it. A supervisor restarts one of them if it dies.
- THERE IS NO GPU, and it does not matter: the adapter is `Vulkan · llvmpipe` (lavapipe,
  Mesa's software rasterizer), which the app's own capture module names as the last tier of
  headless pictures. The app opens a real window with it and `ui.screenshot` works.
  `/dev/dri` is absent, and that is NOT the thing that blocks the capture.
- `ui.screenshot` captures the window WITH the egui overlay (where the dialog and its
  messages are drawn). `ui.render` only draws the 3D scene and misses all of it.
- The app processes ONE pointer event PER FRAME, so between a move and a click the loop has
  to run: the reference does a "pump" of several `ui.inspect` calls with ~60 ms between
  each one.
- The evidence for a reviewer is worth more than the picture: report the `ui.inspect` /
  `ui.handles` state too. A handle that is published before the fix and NOT published after
  it is the difference between "the button is gone in a picture" and "the button is not
  there".
- Two states do not need two builds. Compiling the workspace twice (once for BEFORE and once
  for AFTER) cost tens of GB each and filled the disk: the BEFORE can be captured from the
  same build when the old behaviour is reachable in it, or from a capture that already
  exists. And a target dir is a CACHE, not evidence: the evidence is the PNG, in the fork.
- Capturing on a headless box needs the software-renderer path, not a GPU: the repo exposes
  a software rendering mode and a CPU capture mode, and an Xvfb display works when no
  `/dev/dri` device exists. Verify those flags exist in the repo before scripting a capture
  around them rather than assuming a display is available.

## An agent that concludes "there is no display and no GPU, so it cannot be captured" is wrong
This exact sentence appeared in the body of a pull request while three other agents were
capturing screenshots on the same machine at the same time. The agent's own transcript showed
`adapter: Vulkan · llvmpipe` — the software rasterizer it had just mistaken for the absence
of one. Look at the adapter line before believing "no GPU", and tell the agent the environment
is PREPARED: the X servers, the client X libraries and lavapipe as the Vulkan ICD are already
in place.
