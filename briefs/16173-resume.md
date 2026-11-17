# TASK 16173 — RESUME brief (the icon file was measured; here is what it shows)

Issue: https://github.com/tangency-labs/solidcraft/issues/16173

## The report

The reporter: when SolidCraft is put on the Windows task bar, THE LOGO BECOMES A
GREY SQUARE. They report the same for another application (Vector).

## What was ALREADY measured (do not redo it — this is the ground truth)

The executable's icon is `assets/icons/app/windows/exports/solidcraft-executable.ico`.
It was decoded entry by entry (the DIB header is BI_RGB, so the pixel data starts
right after the 40-byte BITMAPINFOHEADER; the ICO directory stores 256 as the byte 0):

    entry  dim      biW  biH   blob bytes  needed  fit   pixels with alpha   fully opaque
    0       16x16     16    32      1128      1128  True    161/256             73
    1       24x24     24    48      2440      2440  True    357/576            191
    2       32x32     32    64      4264      4264  True    587/1024           387
    3       48x48     48    96      9640      9640  True   1206/2304           939
    4       64x64     64   128     16936     16936  True   2091/4096          1695
    5      128x128   128   256     67624     67624  True   8036/16384         7249
    6      256x256   256   512    270376    270376  True  31172/65536         29947

So: EVERY size is present, every size is a well-formed 32-bpp DIB whose length
matches exactly, every size carries real pixels (the mark IS drawn), and the
one-bit AND mask of each entry sets exactly as many bits as there are fully
transparent pixels (16x16: 95 mask bits for 95 transparent pixels). The centre
pixel of the small sizes is orange-ish (BGRA 242,134,46 with a low alpha, i.e. the
edge of the mark), and the solid blue of the mark reads B=198,G=96,R=25.

CONCLUSION: the `.ico` FILE is not broken. The grey square is NOT an empty or
truncated icon file.

## What you must do — exactly this

The defect, if it is ours, is in HOW the icon reaches the task bar. Check these
three, in this order, and stop at the first one you can prove:

### A. The alpha of a 32-bpp icon DIB is supposed to be PREMULTIPLIED

Windows expects the colour channels of a 32-bpp icon DIB to be PREMULTIPLIED by
alpha. `assets/icons/app/shared/source/windows_ico.rs` writes the pixels as

    dib.extend_from_slice(&[p[2], p[1], p[0], p[3]]);

which is RGBA -> BGRA, i.e. STRAIGHT alpha. For a pixel with alpha 47 and colour
(25,96,198) the straight-alpha value keeps the full-strength blue, while a
premultiplied value would be about (2,17,187). Windows renders the straight value
wrongly (too bright) — and a task bar that cannot decode the icon it gets falls
back to a grey block.

Check whether that is what happens, and if so FIX IT: premultiply the colour by
the alpha (rounded) in the encoder. Then the AND mask and the alpha channel stay
as they are.

### B. The window icon at runtime

A Windows task bar entry shows the ICON OF THE WINDOW, and when the window has no
icon set the task bar shows a generic placeholder. Find out whether the app sets
the window icon on Windows: look at the eframe/egui window creation
(`crates/ui-egui/src/`, the `egui::ViewportBuilder` / `with_icon` / the native
window setup) and whether anything loads the icon resource of the executable at
runtime. If nothing does, THAT is why the task bar shows a grey square even
though the resource is in the file.

### C. The icon of the pinned shortcut

The reporter PINNED the app to the task bar. A pinned item shows the icon of the
SHORTCUT, which is read from the executable's icon resource at pin time. If the
executable resource is only embedded by `apps/solidcraft/build.rs` (which returns
early on a non-Windows target) then a build without that resource has no icon at
all. Check whether the Windows build always embeds it and whether the installer
and the shortcut use the same `.ico`.

## Rules

- If you cannot PROVE which of A, B or C is the cause, report what you ruled out
  and open NO pull request. A wrong fix for a Windows-only rendering problem is
  worse than no fix.
- If you DO prove it, the regression test goes in the area's EXISTING test file:
  the tests of `assets/icons/app/shared/source/windows_ico.rs` or the icon test of
  the `xtask`. Do NOT create a new test file. The test must assert the real thing
  (for a premultiplied fix: that a pixel with alpha 128 and colour (200,100,50)
  is stored as the premultiplied value; for the window icon: that the icon is
  actually set on the window).
- Every asset is original or openly licensed and `ATTRIBUTION.md` must have a row
  for anything new. Do NOT bring an icon in from anywhere else: the repository
  draws its own mark (read `assets/AGENTS.md`).
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
Icons: the Windows task bar shows the app mark and not a grey square

Task: https://github.com/tangency-labs/solidcraft/issues/16173
```

- The gate: `cargo fmt --all` and the test of the crate that owns the icon code.
  Save the output to `/home/user/.local/share/solidcraft-orch/logs/16173-GREEN.log`.
- Do not run `cargo xtask ci` (90 minutes).
